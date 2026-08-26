// Cosino shared renderer + drivers.
//
// One canvas scene (felt table, cogs, hole cards, chips, speech bubbles)
// fed by three drivers: live /global websocket, live /player websocket, and
// replay (from the game's /replay websocket or the static wasm bundle).
// All state derivation happens server-side / wasm-side; this file only
// draws table-state objects:
//   {seats:[{name,stack,bet,net,cards,revealed,folded,allIn,acting,
//            handsWon}], board, pot, street, hand, pair, mirror, button,
//    currentBet, handDone}
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
  // The winner's scoop: a long telescoping arm reaches from the cog to the
  // pot, the claw closes, and the arm drags the chips home.
  var SCOOP_MS = 2000;
  var SCOOP_EXTEND = 0.35;   // arm reaching out
  var SCOOP_GRAB = 0.5;      // claw closing on the pile
  var SCOOP_RETRACT = 0.85;  // dragging the chips back; then the +N floats

  var RANKS = "23456789TJQKA";
  var SUITS = ["♣", "♦", "♥", "♠"];

  function cardRank(card) { return Math.floor(card / 4); }
  function cardSuit(card) { return card % 4; }
  function cardLabel(card) {
    // Viewers get "10" like a real deck; "T" is poker shorthand the bots
    // use in their prompts, not something a casual spectator should need.
    var rank = RANKS[cardRank(card)];
    return rank === "T" ? "10" : rank;
  }
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
  // The bubble is sized from the cap the SERVER enforces on a `say`
  // (MaxSayLen = 120 runes, src/cosino/types.nim), measured in the font the
  // bubble draws in (13 px 'rajdhani'): the widest 120 runes that cap admits
  // — every rune a full-width CJK glyph or a playing-card emoji — measure
  // ~1600 px, and 6 lines x 300 px hold that with the wrap's per-line
  // remainder to spare. A cut LABEL is a design choice; a cut SENTENCE is a
  // defect, so a server-capped remark must never reach drawBubble's clip.
  // Grow these together with MaxSayLen, never one without the other.
  var BUBBLE_MAX_W = 300, BUBBLE_LINES = 6, BUBBLE_LINE_H = 16;
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
    // The empty board outlines shrink to the variant's board size: Kuhn has
    // no board at all, Leduc turns one card, Hold'em runs five.
    var boardSlots = view.boardSlots == null ? 5 : view.boardSlots;
    var startX = layout.cx - (boardSlots * cw + (boardSlots - 1) * gap) / 2 +
      cw / 2;
    var highlight = view.highlight || {};
    var highlighting = Object.keys(highlight).length > 0;
    for (var slot = 0; slot < boardSlots; slot++) {
      var cardX = startX + slot * (cw + gap);
      if (slot < board.length) {
        var lit = !!highlight[board[slot]];
        drawCardFace(ctx, cardX, layout.cy - 8 * layout.scale, cw, chh,
          board[slot], highlighting && !lit ? 0.5 : 1, 0, lit);
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
        // Busted out of the chip race: a toppled ghost of a cog.
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
      ctx.fillStyle = (seat.out || seat.stack === 0) ? GHOST : AMBER;
      // On the ladder stacks reset every hand, so an empty stack is a
      // stack-off; on the chip race it is a bust and the seat is out.
      var stackText = seat.out ? "BUST" : "" + seat.stack;
      if (seat.allIn && !seat.out) stackText = "ALL-IN";
      ctx.fillText(stackText, pos.x, pos.y + size * 0.62 + 30 * scale);
      ctx.restore();

      // Hole cards, between the cog and the felt. Kuhn and Leduc deal one.
      var cards = seat.cards || [];
      var holeCount = view.holeCount == null ? 2 : view.holeCount;
      var hasCards = !seat.out && !seat.folded &&
        (cards.length > 0 || view.handLive);
      if (hasCards) {
        var spot = alongCenter(pos, layout, size * 1.3);
        var hw = CARD_W * scale;
        var hh = CARD_H * scale;
        var faceUp = cards.length === holeCount &&
          (view.showAllCards || seat.revealed || seat.own);
        for (var c = 0; c < holeCount; c++) {
          var offset = holeCount === 1 ? 0 :
            (c === 0 ? -1 : 1) * (hw * 0.55 + 1);
          var tilt = holeCount === 1 ? 0 : (c === 0 ? -1 : 1) * 0.06;
          if (faceUp) {
            drawCardFace(ctx, spot.x + offset, spot.y, hw, hh, cards[c],
              1, tilt, !!(view.highlight || {})[cards[c]]);
          } else {
            drawCardBack(ctx, spot.x + offset, spot.y, hw, hh,
              COLOR_HEX[color], tilt);
          }
        }
      }

      // Chips bet this street, closer to the felt. Once the hand is
      // decided the bets have been raked into the pot — stale chips in
      // front of the seats would misread as live action.
      if (seat.bet > 0 && view.handLive && view.street !== "showdown") {
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
    var potSpot = {
      x: layout.cx,
      y: layout.cy + chh / 2 + 12 * layout.scale
    };
    if (view.pot > 0 || board.length > 0) {
      ctx.save();
      ctx.font = "700 " + Math.round(15 * layout.scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.fillStyle = AMBER;
      ctx.shadowColor = "rgba(0,0,0,0.8)";
      ctx.shadowBlur = 4;
      ctx.fillText("POT " + (view.pot || 0), potSpot.x, potSpot.y);
      ctx.restore();
    }

    // Showdown verdicts: what each tabled hand actually was, pinned by
    // its cards until the next deal.
    Object.keys(view.handLabels || {}).forEach(function (key) {
      var index = +key;
      if (index >= seats.length) return;
      var pos = seatPosition(index, count, layout);
      var spot = alongCenter(pos, layout,
        layout.size * 1.3 + (CARD_H / 2 + 13) * layout.scale);
      drawHandTag(ctx, spot.x, spot.y, view.handLabels[key],
        COLOR_HEX[seatColor(index)], layout.scale);
    });

    // Winner scoops, over the pot they are robbing.
    (view.scoops || []).forEach(function (scoop) {
      var age = now - scoop.at;
      if (age > SCOOP_MS) return;
      drawScoop(ctx, scoop, age / SCOOP_MS, count, layout, potSpot);
    });

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

  function easeOut(t) { return 1 - (1 - t) * (1 - t); }
  function easeIn(t) { return t * t; }

  // A small verdict tag ("a flush, ace high") in the seat's color.
  function drawHandTag(ctx, x, y, text, accent, scale) {
    ctx.save();
    ctx.font = "700 " + Math.round(11 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var label = text.toUpperCase();
    var pad = 6 * scale;
    var bw = ctx.measureText(label).width + pad * 2;
    var bh = 17 * scale;
    ctx.fillStyle = "rgba(242, 232, 216, 0.95)";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    roundRect(ctx, x - bw / 2, y - bh / 2, bw, bh, 4 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(label, x, y + scale);
    ctx.restore();
  }

  function drawScoop(ctx, scoop, t, count, layout, potSpot) {
    var pos = seatPosition(scoop.seat, count, layout);
    var color = COLOR_HEX[seatColor(scoop.seat)];
    var scale = layout.scale;
    // Shoulder: the cog's near edge, facing the pot.
    var shoulder = alongCenter(pos, layout, layout.size * 0.42);
    var span = {
      x: potSpot.x - shoulder.x,
      y: potSpot.y - 6 * scale - shoulder.y
    };

    // How far the claw has reached: out, hold to grab, then haul it home.
    var reach;
    if (t < SCOOP_EXTEND) {
      reach = easeOut(t / SCOOP_EXTEND);
    } else if (t < SCOOP_GRAB) {
      reach = 1;
    } else if (t < SCOOP_RETRACT) {
      reach = 1 - easeIn((t - SCOOP_GRAB) / (SCOOP_RETRACT - SCOOP_GRAB));
    } else {
      reach = 0;
    }
    var tip = {
      x: shoulder.x + span.x * reach,
      y: shoulder.y + span.y * reach
    };
    var hauling = t >= SCOOP_GRAB && reach > 0.02;

    if (reach > 0.02) {
      // Telescoping arm: three tapering segments, cog-colored.
      var angle = Math.atan2(tip.y - shoulder.y, tip.x - shoulder.x);
      ctx.save();
      ctx.lineCap = "round";
      for (var seg = 0; seg < 3; seg++) {
        var a = seg / 3;
        var b = (seg + 1) / 3;
        ctx.strokeStyle = seg % 2 ? "#3a3128" : color;
        ctx.lineWidth = (9 - seg * 2.4) * scale;
        ctx.beginPath();
        ctx.moveTo(shoulder.x + (tip.x - shoulder.x) * a,
          shoulder.y + (tip.y - shoulder.y) * a);
        ctx.lineTo(shoulder.x + (tip.x - shoulder.x) * b,
          shoulder.y + (tip.y - shoulder.y) * b);
        ctx.stroke();
      }
      // The claw: two fingers, open on the way out, clamped on the haul.
      var open = hauling ? 0.22 : 0.65;
      ctx.strokeStyle = color;
      ctx.lineWidth = 3.4 * scale;
      [-1, 1].forEach(function (side) {
        ctx.beginPath();
        ctx.arc(tip.x, tip.y, 8 * scale,
          angle + side * open - (side > 0 ? 0 : Math.PI * 0.9),
          angle + side * open + (side > 0 ? Math.PI * 0.9 : 0));
        ctx.stroke();
      });
      // The haul: a little pile of chips gripped in the claw.
      if (hauling) {
        var chipSpots = [[0, 0], [-6, -4], [6, -3], [-2, -8]];
        chipSpots.forEach(function (offset, i) {
          ctx.beginPath();
          ctx.arc(tip.x + offset[0] * scale, tip.y + offset[1] * scale,
            4.6 * scale, 0, Math.PI * 2);
          ctx.fillStyle = i % 2 ? AMBER : PAPER;
          ctx.fill();
          ctx.strokeStyle = "rgba(0,0,0,0.55)";
          ctx.lineWidth = 1;
          ctx.stroke();
        });
      }
      ctx.restore();
    }

    // The winnings land: "+N" floats up from the cog.
    if (t >= SCOOP_RETRACT) {
      var doneT = (t - SCOOP_RETRACT) / (1 - SCOOP_RETRACT);
      ctx.save();
      ctx.globalAlpha = 1 - doneT;
      ctx.font = "700 " + Math.round(17 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.fillStyle = AMBER;
      ctx.shadowColor = "rgba(0,0,0,0.9)";
      ctx.shadowBlur = 5;
      ctx.fillText("+" + scoop.amount, shoulder.x,
        shoulder.y - (8 + doneT * 22) * scale);
      ctx.restore();
    }
  }

  function drawCardFace(ctx, x, y, cw, chh, card, alpha, tilt, glow) {
    ctx.save();
    ctx.translate(x, y);
    if (tilt) ctx.rotate(tilt);
    ctx.globalAlpha = alpha == null ? 1 : alpha;
    ctx.fillStyle = PAPER;
    if (glow) {
      // Part of the hand that took the pot.
      ctx.shadowColor = AMBER;
      ctx.shadowBlur = 14;
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = 3;
    } else {
      ctx.strokeStyle = "rgba(42, 31, 22, 0.8)";
      ctx.lineWidth = 1.5;
    }
    roundRect(ctx, -cw / 2, -chh / 2, cw, chh, cw * 0.13);
    ctx.fill();
    ctx.stroke();
    ctx.restore();

    // The rank and suit are drawn in ABSOLUTE canvas coordinates, outside the
    // card's translate/rotate. A string laid out relative to a transform is
    // invisible to any bounds check -- viewer_smoke.mjs --strict-text-bounds
    // reads the fillText arguments, and every glyph would report at a
    // negative coordinate whatever was actually on screen. The tilt is worth
    // less than the gate.
    ctx.save();
    ctx.globalAlpha = alpha == null ? 1 : alpha;
    ctx.fillStyle = suitColor(card);
    ctx.textAlign = "center";
    ctx.textBaseline = "alphabetic";
    var label = cardLabel(card);
    // "10" is two glyphs where every other rank is one; shrink it a notch
    // so it stays inside the card frame.
    ctx.font = "700 " + Math.round(chh * (label.length > 1 ? 0.32 : 0.38)) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillText(label, x, y - chh * 0.08);
    ctx.font = Math.round(chh * 0.4) + "px system-ui, sans-serif";
    ctx.fillText(suitGlyph(card), x, y + chh * 0.34);
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

  // Wraps a remark to `maxWidth` on whitespace, and splits a single word that
  // is wider than a whole line on RUNE (code point) boundaries. Whitespace
  // alone is not enough: Chinese, Japanese and a wall of emoji carry no
  // spaces at all, and a whitespace-only wrap draws them as one line running
  // off the canvas.
  function wrapBubble(ctx, text, maxWidth) {
    var lines = [];
    var line = "";
    function flush() {
      if (line !== "") {
        lines.push(line);
        line = "";
      }
    }
    text.split(/\s+/).forEach(function (word) {
      if (word === "") return;
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width <= maxWidth) {
        line = probe;
        return;
      }
      flush();
      if (ctx.measureText(word).width <= maxWidth) {
        line = word;
        return;
      }
      Array.from(word).forEach(function (rune) {
        if (line !== "" && ctx.measureText(line + rune).width > maxWidth) {
          flush();
        }
        line += rune;
      });
    });
    flush();
    return lines;
  }

  function drawBubble(ctx, canvasWidth, x, y, text, alpha, scale) {
    var s = scale || 1;
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.font = Math.round(13 * s) + "px 'rajdhani', system-ui, sans-serif";
    // Never wider than the canvas: the box is clamped into frame below, and a
    // box wider than the frame would push its own text off the edge.
    var maxWidth = Math.min(BUBBLE_MAX_W * s,
      canvasWidth - 12 - BUBBLE_PAD * 2 * s);
    var lines = wrapBubble(ctx, text, maxWidth);
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
        return "Shuffle up — " + (event.text || "") + ", button " +
          name(event.seat) + "." +
          (event.mirror ? " Duplicate mirror." : "");
      case "deal":
        return name(event.seat) + " is dealt " + cardsText(event.cards) + ".";
      case "blind":
        return name(event.seat) + " posts the " + event.text + " blind (" +
          event.amount + ")" + (event.allIn ? " — ALL-IN" : "") + ".";
      case "ante":
        return name(event.seat) + " antes " + event.amount + ".";
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
      case "stackOff":
        return name(event.seat) + " is stacked off — chips reset next hand.";
      case "bust":
        return name(event.seat) + " is BUSTED — out of the match.";
      case "handEnd":
        return "Hand complete.";
      case "handVoid":
        return "Hand VOIDED at the deadline — every chip refunded, not scored.";
      case "calib":
        var calib = event.data || {};
        return name(event.seat) + " exploitability " +
          (calib.exploitability == null ? "—" :
            (+calib.exploitability).toFixed(3)) +
          " chips/hand (coverage " +
          (calib.coverage == null ? "—" : (+calib.coverage).toFixed(2)) + ")";
      case "audit":
        var flag = event.data || {};
        var pairText = name(flag.a) + " ↔ " + name(flag.b);
        var head = flag.flag === "soft-play" ? "SOFT PLAY FLAG" : "DUMP FLAG";
        if (flag.flag !== "soft-play") pairText = name(flag.a) + " → " + name(flag.b);
        return head + " — " + pairText + ": " +
          (+(flag.biasAB || 0)).toFixed(2) +
          " chips/hand of equity surrender over " + (flag.contested || 0) +
          " contested hands";
      case "matchEnd":
        var meta = event.data || {};
        return "Match over (" + (meta.reason || "complete") + ") after " +
          (meta.handsScored || 0) + " scored hands.";
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
        // The mirror half of a duplicate pair is labelled: spectators get to
        // see the same deck played from the other side of the table.
        html += '<div class="feed-round-head">HAND ' + (event.hand + 1) +
          (event.kind === "handStart" && event.mirror ?
            " — duplicate mirror of hand " + event.hand : "") + "</div>";
        lastHand = event.hand;
        lastStreet = null;
      }
      if (event.kind === "board" && event.street !== lastStreet) {
        html += '<div class="feed-turn-head">' +
          event.street.toUpperCase() + "</div>";
        lastStreet = event.street;
      }
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "stackOff" || event.kind === "bust" ||
          event.kind === "audit" ? " feed-rwin" : "") +
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
    var scoops = [];
    var handLabels = {};
    var bestFives = {};
    var highlight = {};
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only
      // the newest events get to animate — replaying every historical
      // pot award as a fresh scoop would fill the table with arms.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 2;
          if (event.kind === "handStart") {
            handLabels = {};
            bestFives = {};
            highlight = {};
          } else if (event.kind === "reveal") {
            // The showdown verdict: pinned to the seat until the next deal.
            handLabels[event.seat] = event.text || "";
            bestFives[event.seat] = event.best || [];
          } else if (event.kind === "award" && event.text !== "returned" &&
              bestFives[event.seat]) {
            // The cards that actually took the pot light up.
            bestFives[event.seat].forEach(function (card) {
              highlight[card] = true;
            });
          }
          if (event.kind === "say") {
            if (!animate) continue;
            bubbles = bubbles.filter(function (b) {
              return b.seat !== event.seat;
            });
            bubbles.push({ seat: event.seat, text: event.text, at: now });
          } else if (event.kind === "award" && event.text !== "returned") {
            if (!animate) continue;
            // One scoop per winner: a second pot for the same seat in the
            // same beat folds into the arm already reaching out.
            var merged = false;
            scoops.forEach(function (scoop) {
              if (scoop.seat === event.seat && now - scoop.at < 300) {
                scoop.amount += event.amount;
                merged = true;
              }
            });
            if (!merged) {
              scoops.push({ seat: event.seat, amount: event.amount,
                at: now });
            }
          }
        }
        var cutoff = now - Math.max(BUBBLE_MS, SCOOP_MS);
        bubbles = bubbles.filter(function (b) { return b.at > cutoff; });
        scoops = scoops.filter(function (s) { return s.at > cutoff; });
      },
      reset: function () {
        seen = 0; bubbles = []; scoops = [];
        handLabels = {}; bestFives = {}; highlight = {};
      },
      view: function () {
        return { bubbles: bubbles, scoops: scoops,
          handLabels: handLabels, highlight: highlight };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  // ==== cosino game block begin (appended chrome; the helpers above and
  // below are cosino's, unchanged apart from the edits the design names) ====
  // Nothing declared between these fences may be named like a chrome helper
  // (see CHROME_ALIASES): a game-block `function markBeat` gets shadowed by
  // the hoisted alias binding and vanishes silently (tandem, 2026-08-23).

  var RUNG_LABELS = {
    kuhn: "KUHN",
    leduc: "LEDUC",
    "holdem-2": "NLHE HU",
    holdem: "NLHE 6-MAX"
  };

  function rungLabel(config) {
    if (!config) return "";
    var variant = config.variant || "holdem";
    if (variant === "holdem") {
      var seatsLabel = (config.seats || 2) <= 2 ? RUNG_LABELS["holdem-2"] :
        RUNG_LABELS.holdem;
      return config.chipRace ? seatsLabel + " · CHIP RACE" : seatsLabel;
    }
    return RUNG_LABELS[variant] || variant.toUpperCase();
  }

  function isFixedLimit(config) {
    return !!config && (config.variant === "kuhn" || config.variant === "leduc");
  }

  function boardSlotsFor(config) {
    if (!config) return 5;
    if (config.variant === "kuhn") return 0;
    if (config.variant === "leduc") return 1;
    return 5;
  }

  function holeCountFor(config) {
    return isFixedLimit(config) ? 1 : 2;
  }

  // Round label for the calibration rungs, street name for Hold'em.
  function streetLabel(state, config) {
    if (!state || !state.street) return "";
    if (state.street === "showdown") return "SHOWDOWN";
    if (!isFixedLimit(config)) return state.street.toUpperCase();
    return state.street === "preflop" ? "ROUND 1" : "ROUND 2";
  }

  // Cumulative net INCLUDING whatever this hand has moved so far: `net` is
  // the running total before the hand, and every hand starts on the same
  // stack, so the live delta is stack - startingStack.
  function liveNet(seat, config) {
    var base = seat.net || 0;
    if (!config || config.startingStack == null) return base;
    return base + ((seat.stack || 0) - config.startingStack);
  }

  function signed(value) {
    return (value > 0 ? "+" : value < 0 ? "\u2212" : "") + Math.abs(value);
  }

  function updateRungChip(element, config) {
    if (!element) return;
    var label = rungLabel(config);
    if (element.textContent !== label) element.textContent = label;
  }

  // ==== cosino game block end ====

  function matchHeader(state, config) {
    var parts = [];
    if (state) {
      parts.push("HAND " + ((state.hand || 0) + 1) +
        (config && config.hands ? " / " + config.hands : ""));
      if (state.mirror) parts.push("MIRROR");
      var street = streetLabel(state, config);
      if (street) parts.push(street);
      parts.push("POT " + (state.pot || 0));
    }
    if (config) {
      if (isFixedLimit(config)) {
        parts.push("ANTE " + config.ante);
      } else {
        parts.push("BLINDS " + config.smallBlind + "/" + config.bigBlind);
      }
    }
    return parts.join(" · ");
  }

  function updateScorebug(container, state, nameMap, config) {
    if (!container || !state || !state.seats) return;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var pips = "";
      for (var p = 0; p < Math.min(seat.handsWon || 0, 12); p++) {
        pips += '<span class="plate-pip"></span>';
      }
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      var race = !!(config && config.chipRace);
      // The big number is the score axis of this game: SIGNED NET CHIPS on
      // the ladder, the carried STACK on the chip race -- with the chips in
      // front this hand alongside it.
      html += '<div class="plate ' + seatColor(index) +
        (seat.out ? " dead" : "") + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (state.button === index && !seat.out ?
          '<span class="plate-it">D</span>' : "") +
        '<span class="plate-score">' +
        (race ? (seat.out ? 0 : seat.stack) :
          signed(liveNet(seat, config))) +
        "</span>" +
        '<span class="plate-label">' + (race ? "stack" : "net") +
        "</span>" +
        '<span class="plate-front">' + (seat.bet || 0) + "</span>" +
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
    var scored = results.handsScored == null ? (results.handsPlayed || 0) :
      results.handsScored;
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + scored + " HAND" +
      (scored === 1 ? "" : "S") +
      (results.reason && results.reason !== "complete" ?
        " (" + escapeHtml(results.reason.toUpperCase()) + ")" : "") +
      "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' +
      escapeHtml(winners.join(" & ") || "NOBODY") +
      (winners.length > 1 ? " TAKE THE TABLE</div>" :
        " TAKES THE TABLE</div>") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">' + (results.chipRace ? "stack" : "net") +
      "</span>" +
      '<span class="end-head">share</span>' +
      '<span class="end-head">hands won</span>' +
      '<span class="end-head">' + (results.chipRace ? "" : "exploit") +
      "</span>";
    order.forEach(function (i, rank) {
      var winner = results.win && results.win[i];
      var cell = function (value) {
        return '<span class="end-cell' + (winner ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      // Exploitability exists only on the calibration rungs; no exact best
      // response exists at no-limit scale and nothing here pretends otherwise.
      var expl = (results.exploitability || [])[i];
      html += '<span class="end-cell rank' +
        (winner ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (winner ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        (results.chipRace ? cell((results.stacks || [])[i] || 0) :
          cell(signed((results.net || [])[i] || 0))) +
        cell(((results.scores || [])[i] || 0).toFixed(3)) +
        cell((results.handsWon || [])[i] || 0) +
        (results.chipRace ?
          cell((results.busted || [])[i] ? "busted" : "") :
          cell(expl == null ? "—" : (+expl).toFixed(3)));
    });
    html += "</div>";
    var flagged = (results.audit && results.audit.flagged) || [];
    if (flagged.length) {
      html += '<div class="end-flags"><div class="end-flags-head">' +
        "FLAGGED PAIRS</div>";
      flagged.forEach(function (flag) {
        html += '<div class="end-flag-row">' +
          escapeHtml(flag.flag) + " — " +
          escapeHtml(names[flag.a] || ("Seat " + flag.a)) + " / " +
          escapeHtml(names[flag.b] || ("Seat " + flag.b)) + " · bias " +
          (+(flag.biasAB || 0)).toFixed(2) + " over " +
          (flag.contested || 0) + " contested hands</div>";
      });
      html += "</div>";
    }
    html += "</div>";
    container.innerHTML = html;
  }

  // ==== cosino game block begin (appended chrome; the helpers above and
  // below are cosino's, unchanged apart from the edits the design names) ====
  // The collusion panel: hidden unless the replay carries audit findings.
  function updateAuditCard(element, results, nameMap) {
    if (!element) return;
    var audit = (results && results.audit) || null;
    var flagged = (audit && audit.flagged) || [];
    if (!flagged.length) {
      element.classList.remove("show");
      element.innerHTML = "";
      return;
    }
    var power = (audit && audit.power) || {};
    var html = '<div class="audit-head">COLLUSION AUDIT</div>';
    flagged.forEach(function (flag) {
      var a = nameMap ? nameMap.seat(flag.a) : "Seat " + flag.a;
      var b = nameMap ? nameMap.seat(flag.b) : "Seat " + flag.b;
      html += '<div class="audit-row"><span class="audit-flag">' +
        escapeHtml(flag.flag) + "</span> " +
        escapeHtml(clampName(a)) +
        (flag.flag === "soft-play" ? " ↔ " : " → ") +
        escapeHtml(clampName(b)) + " · " +
        (+(flag.biasAB || 0)).toFixed(2) + " bias / " +
        (flag.contested || 0) + " hands</div>";
    });
    html += '<div class="audit-power">' + (power.hands || 0) +
      " hands · median contested " + (power.contestedMedian || 0) +
      " · " + (power.equitySamples || 0) + " runouts · reporting only</div>";
    element.innerHTML = html;
    element.classList.add("show");
  }

  // ==== cosino game block end ====


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
    view.street = state.street;
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
                options.clock.textContent =
                  matchHeader(latest, latest.config);
              }
              updateScorebug(options.scorebug, latest, nameMap,
                latest.config);
              updateRungChip(options.rungchip, latest.config);
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
            done: latest.done,
            boardSlots: boardSlotsFor(latest.config),
            holeCount: holeCountFor(latest.config)
          });
          if (slot >= 0 && view.seats[slot]) view.seats[slot].own = true;
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // ==== cosino game block begin (appended chrome; the helpers above and
  // below are cosino's, unchanged apart from the edits the design names) ====
  // Every kind emitted here has a matching CSS rule in the appended block of
  // chrome.css, and ci.yml greps for that pairing.
  var BEAT_KINDS = ["award", "showdown", "stackoff", "bust", "mirror",
    "void", "audit"];

  function beatKindOf(event) {
    switch (event.kind) {
      case "award": return event.text === "returned" ? null : "award";
      case "reveal": return "showdown";
      case "stackOff": return "stackoff";
      case "bust": return "bust";
      case "handStart": return event.mirror ? "mirror" : null;
      case "handVoid": return "void";
      case "audit": return "audit";
      default: return null;
    }
  }

  function beatLabelOf(event, kind) {
    switch (kind) {
      case "award": return "Hand " + (event.hand + 1) + ": pot of " +
        event.amount + " awarded";
      case "showdown": return "Hand " + (event.hand + 1) + ": showdown — " +
        (event.text || "reveal");
      case "stackoff": return "Hand " + (event.hand + 1) + ": seat stacked off";
      case "bust": return "Hand " + (event.hand + 1) + ": seat busted out";
      case "mirror": return "Hand " + (event.hand + 1) +
        ": duplicate mirror deal";
      case "void": return "Hand " + (event.hand + 1) +
        ": voided at the deadline";
      case "audit": return "Collusion flag: " +
        ((event.data && event.data.flag) || "audit");
      default: return "beat";
    }
  }

  // Clickable, labelled <button>s -- a scrubber beat you cannot seek to is
  // decoration, and an unlabelled one is invisible to a screen reader.
  function buildCosinoBeats(container, events, onSeek) {
    events.forEach(function (event, i) {
      var kind = beatKindOf(event);
      if (!kind) return;
      var marker = document.createElement("button");
      marker.type = "button";
      var seat = typeof event.seat === "number" && event.seat >= 0 ?
        event.seat : 0;
      marker.className = "beat-marker " + kind + " seat" +
        (seat % COLORS.length);
      var label = beatLabelOf(event, kind);
      marker.setAttribute("aria-label", label);
      marker.title = label;
      marker.style.left = ((i + 1) / events.length * 100) + "%";
      marker.onclick = function (evt) {
        evt.stopPropagation();
        onSeek(i + 1);
      };
      container.appendChild(marker);
    });
  }

  // ==== cosino game block end ====

  // Scrubber: a click/drag-to-seek track with one span per hand plus the
  // clickable beat markers above.
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
    buildCosinoBeats(container, events, onSeek);
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
    //           endscreen, rungchip, auditcard, assetBase, payload,
    //           onFirstFrame}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var index = 0;
    var playing = true;
    var lastStep = 0;
    var drawnOnce = false;

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
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) renderFeed(options.feed, events, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent =
            matchHeader(currentState(), payload.config);
        }
        updateScorebug(options.scorebug, currentState(), nameMap,
          payload.config);
        // Called on EVERY index change, so any scrub away from the end
        // dismisses the endcard.
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
      }
      updateRungChip(options.rungchip, payload.config);
      updateAuditCard(options.auditcard, payload.results, nameMap);
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at — the event
        // just absorbed — so bubbles get read and the winner's scoop arm
        // gets to play out before the next beat.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = shown && shown.kind === "say" ? 1500 :
          shown && (shown.kind === "board" || shown.kind === "reveal") ? 1200 :
          shown && shown.kind === "award" && shown.text !== "returned" ? 1900 :
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
          done: index >= events.length && events.length > 0,
          boardSlots: boardSlotsFor(payload.config),
          holeCount: holeCountFor(payload.config)
        });
        renderer.draw(view);
        if (!drawnOnce) {
          drawnOnce = true;
          // The attribute goes up on the FIRST DRAWN FRAME, and the host
          // bridge fires from the same callback -- so "ready" can never
          // disagree with data-replay-loaded (chorus 3c11c953, 2026-08-24).
          document.documentElement.setAttribute("data-replay-loaded", "true");
          if (options.onFirstFrame) {
            try { options.onFirstFrame(); } catch (ignore) {}
          }
        }
        requestAnimationFrame(frame);
      })(0);
    });
  }

  // Chrome helpers the game block must never shadow. ci.yml greps this list
  // against every function declared below the game-block marker.
  var CHROME_ALIASES = ["attachLive", "attachReplay", "renderFeed",
    "bindFeedToggle", "buildScrub", "updateScorebug", "updateEndscreen",
    "makeNameMap", "makeRenderer", "makeEffects", "matchHeader", "markBeat",
    "draw", "stateToView"];

  window.CosinoRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle,
    buildCosinoBeats: buildCosinoBeats,
    beatKinds: BEAT_KINDS,
    chromeAliases: CHROME_ALIASES
  };
})();
