// Cosino shared renderer + drivers.
//
// One canvas scene (felt table, cogs, hole cards, chips, speech bubbles)
// fed by three drivers: live /global websocket, live /player websocket, and
// replay (from the game's /replay websocket or the static wasm bundle).
// All state derivation happens server-side / wasm-side; this file only
// draws table-state objects:
//   {seats:[{name,stack,bet,cards,revealed,folded,allIn,out,acting,
//            handsWon}], board, pot, street, hand, button, handDone}
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Four
  // cog skins ship with the CTF art; extra seats are tinted at load (see
  // tintedSprite) so no two cogs share an identity.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var TINTED_FROM = { violet: "red", orange: "yellow" };
  var TINT_ROTATE = { violet: 265, orange: 330 };
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var FELT = "#2d5c3f";
  var FELT_EDGE = "#1d3f2b";
  var CARD_RED = "#c0392b";
  var BUBBLE_MS = 5200;
  var FLASH_MS = 2200;

  var RANKS = "23456789TJQKA";
  var SUITS = ["♣", "♦", "♥", "♠"];

  function cardRank(card) { return Math.floor(card / 4); }
  function cardSuit(card) { return card % 4; }
  function cardLabel(card) { return RANKS[cardRank(card)]; }
  function suitGlyph(card) { return SUITS[cardSuit(card)]; }
  function suitColor(card) {
    var suit = cardSuit(card);
    return suit === 1 || suit === 2 ? CARD_RED : INK;
  }

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  // Recolors a shipped sprite via an offscreen canvas, so a seat with no
  // art of its own still reads as its own cog instead of a duplicate.
  function tintedSprite(source, degrees) {
    if (!source || !source.width) return source;
    var off = document.createElement("canvas");
    off.width = source.width;
    off.height = source.height;
    var octx = off.getContext("2d");
    octx.filter = "hue-rotate(" + degrees + "deg) saturate(1.15)";
    octx.imageSmoothingEnabled = false;
    octx.drawImage(source, 0, 0);
    return off;
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = [];
    COLORS.forEach(function (c) {
      if (TINTED_FROM[c]) return;
      names.push("soldier_" + c + "_front.png");
    });
    names.push("arena_floor.png");
    loadImages(assetBase, names, function (images) {
      Object.keys(TINTED_FROM).forEach(function (color) {
        images["soldier_" + color + "_front.png"] = tintedSprite(
          images["soldier_" + TINTED_FROM[color] + "_front.png"],
          TINT_ROTATE[color]
        );
      });
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  // Nominal cog size; everything around a cog is measured as a multiple of
  // it so the whole seat scales as one block.
  var SEAT_BASE = 84;
  var CARD_W = 30, CARD_H = 42;
  var BUBBLE_MAX_W = 220, BUBBLE_LINES = 4, BUBBLE_LINE_H = 16;
  var BUBBLE_PAD = 8, BUBBLE_TAIL = 8, BUBBLE_RISE = 0.69;

  function bubbleHeight(lines) {
    return lines * BUBBLE_LINE_H + BUBBLE_PAD * 2 - 4;
  }

  function seatExtent(size) {
    // How far one seat reaches above and below its cog's centre: a speech
    // bubble above, the name/stack rows below. Hole cards and bets sit
    // toward the table centre, so they need no ring reserve.
    //
    // Bubble headroom is reserved at its WORST case (four lines) even
    // while nobody is talking: bubbles are transient and arrive without
    // warning, and sizing the ring to the quiet table would clip the one
    // thing on screen anyone is reading.
    var scale = size / SEAT_BASE;
    return {
      above: size * BUBBLE_RISE + bubbleHeight(BUBBLE_LINES) * scale,
      below: size * 0.62 + 40 * scale,
      half: Math.max(size / 2, 52 * scale)
    };
  }

  function seatsCollide(count, layout, ext) {
    var solidAbove = layout.size / 2;
    for (var i = 0; i < count; i++) {
      var a = seatPosition(i, count, layout);
      var b = seatPosition((i + 1) % count, count, layout);
      var dx = Math.abs(a.x - b.x);
      var dy = Math.abs(a.y - b.y);
      if (dx < ext.half * 2 && dy < solidAbove + ext.below) return true;
    }
    return false;
  }

  function computeLayout(width, height, count) {
    // Push the seat ring to the canvas edges so the table fills the panel;
    // cogs only shrink when neighbouring seats would actually collide.
    // Callers embed this viewer at wildly different sizes, so the fit is
    // solved per frame rather than assumed.
    var margin = 10;
    var size = Math.min(SEAT_BASE, (width / count) * 0.9);
    var layout;
    for (var attempt = 0; attempt < 40; attempt++) {
      var ext = seatExtent(size);
      var rx = (width - 2 * margin - 2 * ext.half) / 2;
      var ry = (height - 2 * margin - ext.above - ext.below) / 2;
      layout = {
        size: size,
        scale: size / SEAT_BASE,
        cx: width / 2,
        cy: margin + ext.above + Math.max(ry, 0),
        rx: Math.max(rx, 0),
        ry: Math.max(ry, 0)
      };
      if (rx > 0 && ry > 0 && !seatsCollide(count, layout, ext)) break;
      size *= 0.92;
    }
    return layout;
  }

  function seatPosition(index, count, layout) {
    // Seat 0 at the bottom, going clockwise around the table.
    var angle = Math.PI / 2 + (index * 2 * Math.PI) / count;
    return {
      x: layout.cx + layout.rx * Math.cos(angle),
      y: layout.cy + layout.ry * Math.sin(angle)
    };
  }

  function towardCenter(pos, layout, fraction) {
    return {
      x: layout.cx + (pos.x - layout.cx) * fraction,
      y: layout.cy + (pos.y - layout.cy) * fraction
    };
  }

  // A fixed step from the cog toward the table centre. Fraction-based
  // placement lands top/bottom seats' cards on their own nameplates (the
  // centre is on the same side as the label); a fixed offset clears the
  // whole seat block whatever the ellipse's shape.
  function alongCenter(pos, layout, distance) {
    var dx = layout.cx - pos.x;
    var dy = layout.cy - pos.y;
    var len = Math.sqrt(dx * dx + dy * dy) || 1;
    return { x: pos.x + dx / len * distance, y: pos.y + dy / len * distance };
  }

  // The point where the cog-to-centre line crosses the felt, stepped
  // `inset` further in. Bets live just inside the rail: a fixed distance
  // would sit right for the near (top/bottom) seats and on top of the
  // side seats' own cards, because the felt is much farther sideways.
  function feltEdgePoint(pos, layout, feltRx, feltRy, inset) {
    var ex = (pos.x - layout.cx) / feltRx;
    var ey = (pos.y - layout.cy) / feltRy;
    var outside = Math.sqrt(ex * ex + ey * ey);
    var t = outside > 1 ? 1 - 1 / outside : 0;
    var dx = layout.cx - pos.x;
    var dy = layout.cy - pos.y;
    var len = Math.sqrt(dx * dx + dy * dy) || 1;
    return {
      x: pos.x + dx * t + dx / len * inset,
      y: pos.y + dy * t + dy / len * inset
    };
  }

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var seats = view.seats || [];
    var count = Math.max(seats.length, 2);
    var now = view.now || Date.now();
    var layout = computeLayout(w, h, count);

    // Floor.
    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.45)";
    ctx.fillRect(0, 0, w, h);

    // The felt: an ellipse inside the seat ring.
    var feltRx = Math.max(layout.rx * 0.62, 120 * layout.scale);
    var feltRy = Math.max(layout.ry * 0.58, 70 * layout.scale);
    ctx.save();
    ctx.beginPath();
    ctx.ellipse(layout.cx, layout.cy, feltRx, feltRy, 0, 0, Math.PI * 2);
    ctx.fillStyle = FELT;
    ctx.fill();
    ctx.lineWidth = 8 * layout.scale;
    ctx.strokeStyle = FELT_EDGE;
    ctx.stroke();
    ctx.lineWidth = 2 * layout.scale;
    ctx.strokeStyle = "rgba(242, 232, 216, 0.25)";
    ctx.beginPath();
    ctx.ellipse(layout.cx, layout.cy, feltRx * 0.86, feltRy * 0.8, 0, 0,
      Math.PI * 2);
    ctx.stroke();
    ctx.restore();

    // Community cards and the pot.
    var board = view.board || [];
    var cw = CARD_W * layout.scale * 1.25;
    var chh = CARD_H * layout.scale * 1.25;
    var gap = 6 * layout.scale;
    var startX = layout.cx - (5 * cw + 4 * gap) / 2 + cw / 2;
    for (var slot = 0; slot < 5; slot++) {
      var cardX = startX + slot * (cw + gap);
      if (slot < board.length) {
        drawCardFace(ctx, cardX, layout.cy - 8 * layout.scale, cw, chh,
          board[slot], 1);
      } else {
        // Empty slot outline, so the board reads as five-card even preflop.
        ctx.save();
        ctx.strokeStyle = "rgba(242, 232, 216, 0.18)";
        ctx.lineWidth = 1.5;
        roundRect(ctx, cardX - cw / 2, layout.cy - 8 * layout.scale - chh / 2,
          cw, chh, 4 * layout.scale);
        ctx.stroke();
        ctx.restore();
      }
    }
    // Award flashes: winning chips announce themselves at the winner.
    (view.flashes || []).forEach(function (flash) {
      var age = now - flash.at;
      if (age > FLASH_MS) return;
      var pos = seatPosition(flash.seat, count, layout);
      var spot = alongCenter(pos, layout, layout.size * 1.2);
      var alpha = Math.max(0, 1 - age / FLASH_MS);
      var rise = (age / FLASH_MS) * 26 * layout.scale;
      ctx.save();
      ctx.globalAlpha = alpha;
      ctx.font = "700 " + Math.round(16 * layout.scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.fillStyle = AMBER;
      ctx.shadowColor = "rgba(0,0,0,0.9)";
      ctx.shadowBlur = 5;
      ctx.fillText("+" + flash.amount, spot.x, spot.y - rise);
      ctx.restore();
    });

    // Seats.
    seats.forEach(function (seat, index) {
      var pos = seatPosition(index, count, layout);
      var color = seatColor(index);
      var sprite = images["soldier_" + color + "_front.png"];
      var size = layout.size;
      var scale = layout.scale;
      var sunk = seat.out || seat.folded;

      ctx.save();
      ctx.translate(pos.x, pos.y);
      if (seat.out) {
        ctx.globalAlpha = 0.28;
        ctx.rotate(Math.PI / 2);
      } else if (seat.folded) {
        ctx.globalAlpha = 0.45;
      }
      if (sprite && sprite.width) {
        ctx.imageSmoothingEnabled = false;
        ctx.drawImage(sprite, -size / 2, -size / 2, size, size);
      } else {
        ctx.fillStyle = COLOR_HEX[color];
        ctx.fillRect(-size / 3, -size / 3, size / 1.5, size / 1.5);
      }
      ctx.restore();

      // Acting halo.
      if (seat.acting && !sunk) {
        ctx.save();
        ctx.strokeStyle = AMBER;
        ctx.lineWidth = 3;
        ctx.setLineDash([6, 5]);
        ctx.beginPath();
        ctx.arc(pos.x, pos.y, size * 0.62, 0, Math.PI * 2);
        ctx.stroke();
        ctx.restore();
      }

      // Dealer button: a small chip pinned beside the cog.
      if (view.button === index && !seat.out) {
        var bx = pos.x + size * 0.55;
        var by = pos.y - size * 0.4;
        ctx.save();
        ctx.beginPath();
        ctx.arc(bx, by, 9 * scale, 0, Math.PI * 2);
        ctx.fillStyle = PAPER;
        ctx.fill();
        ctx.strokeStyle = INK;
        ctx.lineWidth = 1.5;
        ctx.stroke();
        ctx.fillStyle = INK;
        ctx.font = "700 " + Math.round(10 * scale) +
          "px 'rajdhani', system-ui, sans-serif";
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillText("D", bx, by + 0.5);
        ctx.restore();
      }

      // Name and stack.
      ctx.save();
      ctx.font = "600 " + Math.round(13 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.fillStyle = seat.out ? GHOST : PAPER;
      ctx.shadowColor = "rgba(0,0,0,0.8)";
      ctx.shadowBlur = 4;
      ctx.fillText(ellipsize(ctx, seat.name, size * 1.35), pos.x,
        pos.y + size * 0.62 + 14 * scale);
      ctx.font = "700 " + Math.round(14 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = seat.out ? GHOST : AMBER;
      var stackText = seat.out ? "BUST" : "" + seat.stack;
      if (seat.allIn && !seat.out) stackText = "ALL-IN";
      ctx.fillText(stackText, pos.x, pos.y + size * 0.62 + 30 * scale);
      ctx.restore();

      // Hole cards, between the cog and the felt.
      var cards = seat.cards || [];
      var hasCards = !seat.out && !seat.folded &&
        (cards.length > 0 || view.handLive);
      if (hasCards) {
        var spot = alongCenter(pos, layout, size * 1.3);
        var hw = CARD_W * scale;
        var hh = CARD_H * scale;
        var faceUp = cards.length === 2 &&
          (view.showAllCards || seat.revealed || seat.own);
        for (var c = 0; c < 2; c++) {
          var offset = (c === 0 ? -1 : 1) * (hw * 0.55 + 1);
          var tilt = (c === 0 ? -1 : 1) * 0.06;
          if (faceUp) {
            drawCardFace(ctx, spot.x + offset, spot.y, hw, hh, cards[c],
              1, tilt);
          } else {
            drawCardBack(ctx, spot.x + offset, spot.y, hw, hh,
              COLOR_HEX[color], tilt);
          }
        }
      }

      // Chips bet this street, closer to the felt.
      if (seat.bet > 0) {
        var betSpot = feltEdgePoint(pos, layout, feltRx, feltRy,
          26 * scale);
        ctx.save();
        ctx.beginPath();
        ctx.arc(betSpot.x - 12 * scale, betSpot.y, 6 * scale, 0,
          Math.PI * 2);
        ctx.fillStyle = COLOR_HEX[color];
        ctx.fill();
        ctx.strokeStyle = "rgba(0,0,0,0.5)";
        ctx.stroke();
        ctx.font = "700 " + Math.round(13 * scale) +
          "px 'rajdhani', system-ui, sans-serif";
        ctx.textAlign = "left";
        ctx.textBaseline = "middle";
        ctx.fillStyle = PAPER;
        ctx.shadowColor = "rgba(0,0,0,0.8)";
        ctx.shadowBlur = 3;
        ctx.fillText("" + seat.bet, betSpot.x - 3 * scale, betSpot.y);
        ctx.restore();
      }
    });

    // The pot, over everything on the felt so it always reads.
    if (view.pot > 0 || board.length > 0) {
      ctx.save();
      ctx.font = "700 " + Math.round(15 * layout.scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.fillStyle = AMBER;
      ctx.shadowColor = "rgba(0,0,0,0.8)";
      ctx.shadowBlur = 4;
      ctx.fillText("POT " + (view.pot || 0), layout.cx,
        layout.cy + chh / 2 + 12 * layout.scale);
      ctx.restore();
    }

    // Speech bubbles (drawn last, on top).
    (view.bubbles || []).forEach(function (bubble) {
      var age = now - bubble.at;
      if (age > BUBBLE_MS) return;
      var pos = seatPosition(bubble.seat, count, layout);
      var alpha = age > BUBBLE_MS - 600 ? (BUBBLE_MS - age) / 600 : 1;
      drawBubble(ctx, w, pos.x, pos.y - layout.size * BUBBLE_RISE,
        bubble.text, alpha, layout.scale);
    });
  }

  function drawCardFace(ctx, x, y, cw, chh, card, alpha, tilt) {
    ctx.save();
    ctx.translate(x, y);
    if (tilt) ctx.rotate(tilt);
    ctx.globalAlpha = alpha == null ? 1 : alpha;
    ctx.fillStyle = PAPER;
    ctx.strokeStyle = "rgba(42, 31, 22, 0.8)";
    ctx.lineWidth = 1.5;
    roundRect(ctx, -cw / 2, -chh / 2, cw, chh, cw * 0.13);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = suitColor(card);
    ctx.textAlign = "center";
    ctx.font = "700 " + Math.round(chh * 0.38) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textBaseline = "alphabetic";
    ctx.fillText(cardLabel(card), 0, -chh * 0.08);
    ctx.font = Math.round(chh * 0.4) + "px system-ui, sans-serif";
    ctx.fillText(suitGlyph(card), 0, chh * 0.34);
    ctx.restore();
  }

  function drawCardBack(ctx, x, y, cw, chh, accent, tilt) {
    ctx.save();
    ctx.translate(x, y);
    if (tilt) ctx.rotate(tilt);
    ctx.fillStyle = "#4a3b2a";
    ctx.strokeStyle = "rgba(42, 31, 22, 0.9)";
    ctx.lineWidth = 1.5;
    roundRect(ctx, -cw / 2, -chh / 2, cw, chh, cw * 0.13);
    ctx.fill();
    ctx.stroke();
    ctx.strokeStyle = accent || AMBER;
    ctx.lineWidth = 1.5;
    roundRect(ctx, -cw / 2 + 3, -chh / 2 + 3, cw - 6, chh - 6, cw * 0.1);
    ctx.stroke();
    ctx.globalAlpha = 0.5;
    ctx.beginPath();
    ctx.arc(0, 0, cw * 0.18, 0, Math.PI * 2);
    ctx.stroke();
    ctx.restore();
  }

  function drawBubble(ctx, canvasWidth, x, y, text, alpha, scale) {
    var s = scale || 1;
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.font = Math.round(13 * s) + "px 'rajdhani', system-ui, sans-serif";
    var maxWidth = BUBBLE_MAX_W * s;
    var words = text.split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > BUBBLE_LINES;
    lines = lines.slice(0, BUBBLE_LINES);
    if (overflow && lines.length) {
      lines[lines.length - 1] += "…";
    }
    var widest = 0;
    lines.forEach(function (l) {
      widest = Math.max(widest, ctx.measureText(l).width);
    });
    var pad = BUBBLE_PAD * s;
    var lineH = BUBBLE_LINE_H * s;
    var bw = widest + pad * 2;
    var bh = lines.length * lineH + pad * 2 - 4 * s;
    var bx = Math.max(6, Math.min(x - bw / 2, canvasWidth - bw - 6));
    var by = y - bh;

    ctx.fillStyle = "rgba(242, 232, 216, 0.96)";
    ctx.strokeStyle = "rgba(42, 31, 22, 0.9)";
    ctx.lineWidth = 1.5;
    roundRect(ctx, bx, by, bw, bh, 8 * s);
    ctx.fill();
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(x - 6 * s, by + bh);
    ctx.lineTo(x + 6 * s, by + bh);
    ctx.lineTo(x, by + bh + BUBBLE_TAIL * s);
    ctx.closePath();
    ctx.fill();

    ctx.fillStyle = INK;
    lines.forEach(function (l, i) {
      ctx.fillText(l, bx + pad, by + pad + 11 * s + i * lineH);
    });
    ctx.restore();
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous table names ("Tinker", "Gasket");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function renameBubbles(bubbles, nameMap) {
    return (bubbles || []).map(function (bubble) {
      return { seat: bubble.seat, text: nameMap.text(bubble.text),
        at: bubble.at };
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  function cardsText(cards) {
    return (cards || []).map(function (card) {
      return cardLabel(card) + suitGlyph(card);
    }).join(" ");
  }

  // ---- Event feed ----------------------------------------------------------

  function describeEvent(event, nameMap) {
    function name(i) {
      return clampName(nameMap.seat(i));
    }
    switch (event.kind) {
      case "handStart":
        return "Shuffle up — blinds " + (event.text || "") + ", button " +
          name(event.seat) + ".";
      case "deal":
        return name(event.seat) + " is dealt " + cardsText(event.cards) + ".";
      case "blind":
        return name(event.seat) + " posts the " + event.text + " blind (" +
          event.amount + ")" + (event.allIn ? " — ALL-IN" : "") + ".";
      case "say":
        return name(event.seat) + ": “" + nameMap.text(event.text) + "”";
      case "action":
        var verb;
        switch (event.action) {
          case "fold": verb = "folds"; break;
          case "check": verb = "checks"; break;
          case "call": verb = "calls " + event.amount; break;
          case "bet": verb = "bets " + event.amount; break;
          default: verb = "raises to " + event.amount;
        }
        return name(event.seat) + " " + verb +
          (event.allIn ? " — ALL-IN!" : "") + ".";
      case "board":
        return "The " + event.street + ": " + cardsText(event.cards);
      case "reveal":
        return name(event.seat) + " shows " + cardsText(event.cards) +
          " — " + (event.text || "") + ".";
      case "award":
        if (event.text === "returned") {
          return event.amount + " uncalled returns to " + name(event.seat) +
            ".";
        }
        return name(event.seat) + " wins " + event.amount + " (" +
          event.text + " pot).";
      case "bust":
        return name(event.seat) + " is FELTED — out of the game!";
      case "handEnd":
        return "Hand complete.";
      default: return JSON.stringify(event);
    }
  }

  // Renders the full transcript grouped into one section per hand with
  // street sub-heads. currentIndex (replay) marks how far playback has
  // reached; omit it for live views.
  function renderFeed(element, events, nameMap, currentIndex) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var html = "";
    var lastHand = null;
    var lastStreet = null;
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      // Secret deals stay off the public transcript; the cards render on
      // the table. (Spectator payloads carry them, but the feed reads
      // better as the table heard it.)
      if (event.kind === "deal") continue;
      if (event.hand !== lastHand) {
        html += '<div class="feed-round-head">HAND ' +
          (event.hand + 1) + "</div>";
        lastHand = event.hand;
        lastStreet = null;
      }
      if (event.kind === "board" && event.street !== lastStreet) {
        html += '<div class="feed-turn-head">' +
          event.street.toUpperCase() + "</div>";
        lastStreet = event.street;
      }
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "bust" ? " feed-rwin" : "") +
        (event.kind === "award" && event.text !== "returned" ?
          " feed-score seat" + (event.seat % COLORS.length) : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' +
        escapeHtml(describeEvent(event, nameMap)) + "</div>";
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    var seen = 0;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects.
  function makeEffects() {
    var seen = 0;
    var bubbles = [];
    var flashes = [];
    return {
      absorb: function (events) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          if (event.kind === "say") {
            bubbles = bubbles.filter(function (b) {
              return b.seat !== event.seat;
            });
            bubbles.push({ seat: event.seat, text: event.text, at: now });
          } else if (event.kind === "award" && event.text !== "returned") {
            flashes.push({ seat: event.seat, amount: event.amount, at: now });
          }
        }
        var cutoff = now - Math.max(BUBBLE_MS, FLASH_MS);
        bubbles = bubbles.filter(function (b) { return b.at > cutoff; });
        flashes = flashes.filter(function (f) { return f.at > cutoff; });
      },
      reset: function () {
        seen = 0; bubbles = []; flashes = [];
      },
      view: function () {
        return { bubbles: bubbles, flashes: flashes };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  function matchHeader(state, config) {
    var parts = [];
    if (state) {
      parts.push("HAND " + ((state.hand || 0) + 1) +
        (config && config.hands ? " / " + config.hands : ""));
      if (state.street && state.street !== "showdown") {
        parts.push(state.street.toUpperCase());
      } else if (state.street === "showdown") {
        parts.push("SHOWDOWN");
      }
      parts.push("POT " + (state.pot || 0));
    }
    if (config) {
      parts.push("BLINDS " + config.smallBlind + "/" + config.bigBlind);
    }
    return parts.join(" · ");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var pips = "";
      for (var p = 0; p < Math.min(seat.handsWon || 0, 12); p++) {
        pips += '<span class="plate-pip"></span>';
      }
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      html += '<div class="plate ' + seatColor(index) +
        (seat.out ? " dead" : "") + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (state.button === index && !seat.out ?
          '<span class="plate-it">D</span>' : "") +
        '<span class="plate-score">' + (seat.out ? 0 : seat.stack) +
        "</span>" +
        '<span class="plate-label">chips</span>' +
        '<span class="plate-pips">' + pips + "</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  // Final standings overlay: verdict up top, ranked rows below.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) {
      return (results.scores[b] || 0) - (results.scores[a] || 0);
    });
    var winners = [];
    names.forEach(function (name, i) {
      if (results.win && results.win[i]) winners.push(name);
    });
    var verdictColor = "";
    if (results.win) {
      var winnerIndex = results.win.indexOf(true);
      if (winnerIndex >= 0) verdictColor = seatColor(winnerIndex);
    }
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' +
      (results.handsPlayed || 0) + " HAND" +
      ((results.handsPlayed || 0) === 1 ? "" : "S") + "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' +
      escapeHtml(winners.join(" & ") || "NOBODY") +
      (winners.length > 1 ? " TAKE THE TABLE</div>" :
        " TAKES THE TABLE</div>") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">chips</span>' +
      '<span class="end-head">share</span>' +
      '<span class="end-head">hands won</span>' +
      '<span class="end-head"></span>';
    order.forEach(function (i, rank) {
      var winner = results.win && results.win[i];
      var cell = function (value) {
        return '<span class="end-cell' + (winner ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (winner ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (winner ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell((results.stacks || [])[i] || 0) +
        cell(((results.scores || [])[i] || 0).toFixed(2)) +
        cell((results.handsWon || [])[i] || 0) +
        cell((results.busted || [])[i] ? "busted" : "");
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(state.seats, nameMap);
    view.bubbles = renameBubbles(view.bubbles, nameMap);
    view.board = state.board;
    view.pot = state.pot;
    view.button = state.button;
    view.handLive = !state.handDone;
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var slot = -1;
      // Player pages get no policyNames (they must not learn who is
      // behind a seat), so their map degrades to the table aliases.
      var nameMap = makeNameMap([], null);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = data;
            if (latest) {
              if (typeof latest.slot === "number") slot = latest.slot;
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
              effects.absorb(latest.events || []);
              if (options.feed) {
                renderFeed(options.feed, latest.events || [], nameMap,
                  undefined);
              }
              if (options.clock) {
                options.clock.textContent = matchHeader(latest, latest);
              }
              updateScorebug(options.scorebug, latest, nameMap);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap);
            }
            if (latest && latest.done) setStatus("final", false);
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      (function frame() {
        if (latest) {
          var view = stateToView(latest, nameMap, effects, {
            // The global page carries policyNames; it is the spectator
            // view and sees every hole card. A player page sees only its
            // own seat's (the rest arrive redacted anyway).
            showAllCards: !!latest.policyNames,
            done: latest.done
          });
          if (slot >= 0 && view.seats[slot]) view.seats[slot].own = true;
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per hand, a marker
  // per pot award (colored by the winner) and per bust (taller).
  function buildScrub(container, events, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var handStarts = [];
    events.forEach(function (event, i) {
      if (event.kind === "handStart") handStarts.push(i);
    });
    handStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < handStarts.length ?
        handStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    events.forEach(function (event, i) {
      var kind = event.kind;
      var isWin = kind === "award" && event.text !== "returned";
      if (!isWin && kind !== "bust") return;
      var marker = document.createElement("div");
      marker.className = "beat-marker seat" + (event.seat % COLORS.length) +
        (kind === "bust" ? " death" : "");
      marker.style.left = ((i + 1) / events.length * 100) + "%";
      container.appendChild(marker);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var index = 0;
    var playing = true;
    var lastStep = 0;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], board: [], pot: 0 };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index));
        if (options.feed) renderFeed(options.feed, events, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent =
            matchHeader(currentState(), payload.config);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        var next = events[index];
        var stepMs = next && next.kind === "say" ? 1500 :
          next && (next.kind === "board" || next.kind === "reveal") ? 1200 :
          700;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var view = stateToView(currentState(), nameMap, effects, {
          showAllCards: true,
          done: index >= events.length && events.length > 0
        });
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.CosinoRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle
  };
})();
