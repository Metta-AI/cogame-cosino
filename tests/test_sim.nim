## The rules engine, the duplicate deck, the scoring, and the invariant that
## everything the platform reads re-derives from the recorded event log.

import std/[algorithm, json, os, random, sequtils, strutils, unicode, unittest]
import cosino/[llm, sim]

# ---- Fixtures ---------------------------------------------------------------

proc fixtureConfig(variant: Variant, players: int, hands = 8,
    seatOrder: seq[int] = @[], duplicate = false): GameConfig =
  result = defaultGameConfig()
  result.variantDefaults(variant)
  result.hands = hands
  result.duplicate = duplicate
  result.randomiseSeating = false
  result.seatOrder = seatOrder
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< players:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc names(config: GameConfig): seq[string] =
  tableNames(config.players, config.seed)

proc freshHand(config: GameConfig, deck: seq[int] = @[], hand = 0): Sim =
  let n = config.players.len
  initHand(config, hand, config.names, newSeq[int](n), newSeq[int](n), deck)

proc act(sim: var Sim, kind: ActionKind, amount = 0) =
  sim.applyAction(sim.actingSeat, PlayerAction(kind: kind, amount: amount))

proc riggedDeck(holes: seq[string], board: string): seq[int] =
  ## Hole strings per seat in DEAL order, then the board; the rest of the deck
  ## is filled with the unused cards.
  for hole in holes:
    result.add(parseCards(hole))
  result.add(parseCards(board))
  for card in 0 ..< 52:
    if card notin result:
      result.add(card)

proc totalStacks(sim: Sim): int =
  for seat in sim.seats:
    result += seat.stack
  result += sim.pot

proc playScriptedHand(match: var Match, baseline = blHouse) =
  let client = newLlmClient(match.config)
  while not match.sim.done:
    let seat = match.sim.actingSeat
    match.sim.applyAction(seat,
      client.scriptedAction(match.sim, seat, baseline).action)
  match.finishHand()
  if not match.done:
    match.nextHand()

proc playScripted(match: var Match, baseline = blHouse) =
  let client = newLlmClient(match.config)
  while not match.done:
    while not match.sim.done:
      let seat = match.sim.actingSeat
      match.sim.applyAction(seat,
        client.scriptedAction(match.sim, seat, baseline).action)
    match.finishHand()
    if not match.done:
      match.nextHand()

# ---- Hold'em betting (cosino's suites, kept) --------------------------------

suite "blinds and order":
  test "multiway blinds sit clockwise from the button":
    ## seatOrder puts slot 1 at position 0, so slot 1 is the button.
    let sim = fixtureConfig(vHoldem, 4, seatOrder = @[1, 2, 3, 0]).freshHand()
    check sim.button == 1
    check sim.sbSeat == 2
    check sim.bbSeat == 3
    check sim.actingSeat == 0   ## UTG, left of the big blind
    check sim.seats[2].committed == 1
    check sim.seats[3].committed == 2
    check sim.pot == 3

  test "heads-up button posts small and acts first":
    let sim = fixtureConfig(vHoldem, 2, seatOrder = @[1, 0]).freshHand()
    check sim.button == 1
    check sim.sbSeat == 1
    check sim.bbSeat == 0
    check sim.actingSeat == 1

  test "every seat plays under an anonymous cog alias":
    let config = fixtureConfig(vHoldem, 3)
    let sim = config.freshHand()
    for index, seat in sim.seats:
      check seat.name != config.players[index].name
      check seat.name in CogNames
      check seat.name.runeLen <= MaxAliasLen

suite "betting":
  test "action space exposes fixed wagers and complete no-limit bounds":
    var leduc = fixtureConfig(vLeduc, 2).freshHand()
    let opening = leduc.actionSpaceJson(leduc.actingSeat)
    check opening.anyIt(it["kind"].getStr() == "bet" and
      it["min"].getInt() == 2 and it["max"].getInt() == 2)
    leduc.act(akBet, 0)
    let facing = leduc.actionSpaceJson(leduc.actingSeat)
    check facing.anyIt(it["kind"].getStr() == "raise" and
      it["min"].getInt() == 4 and it["max"].getInt() == 4)

    let holdem = fixtureConfig(vHoldem, 2).freshHand()
    let noLimit = holdem.actionSpaceJson(holdem.actingSeat)
    check noLimit.anyIt(it["kind"].getStr() == "raise" and
      it["min"].getInt() == 4 and it["max"].getInt() == 100)

  test "folding to the big blind pays it the small blind":
    var sim = fixtureConfig(vHoldem, 3).freshHand()
    sim.act(akFold)          # UTG (button 0 -> sb 1, bb 2, utg 0)
    sim.act(akFold)          # small blind
    check sim.done
    check sim.seats[2].stack == 101
    check sim.seats[1].stack == 99
    check sim.seats[0].stack == 100
    check sim.totalStacks() == 300

  test "cannot check facing a bet, cannot act out of turn":
    var sim = fixtureConfig(vHoldem, 3).freshHand()
    expect CosinoError:
      sim.applyAction(1, PlayerAction(kind: akFold))  # not UTG's turn
    expect CosinoError:
      sim.act(akCheck)                                # UTG owes the blind
    sim.act(akCall)
    check sim.seats[0].committed == 2

  test "big blind gets the option and can raise a limped pot":
    var sim = fixtureConfig(vHoldem, 3).freshHand()
    sim.act(akCall)   # utg limps
    sim.act(akCall)   # sb completes
    check sim.actingSeat == sim.bbSeat
    sim.act(akRaise, 8)
    check sim.currentBet == 8
    check sim.actingSeat == 0

  test "checked-down hand reaches showdown on five board cards":
    var sim = fixtureConfig(vHoldem, 2).freshHand(
      riggedDeck(@["As Ad", "7c 2d"], "Ks Qh 9d 5c 3h"))
    sim.act(akCall)    # sb completes
    sim.act(akCheck)   # bb option
    for street in 0 ..< 3:
      sim.act(akCheck)
      sim.act(akCheck)
    check sim.done
    check sim.board.len == 5
    check sim.seats[0].stack == 102
    check sim.seats[1].stack == 98

  test "minimum raise rules":
    var sim = fixtureConfig(vHoldem, 3).freshHand()
    sim.act(akRaise, 8)
    expect CosinoError:
      sim.act(akRaise, 10)       # min raise-to is 14 (increment 6)
    sim.act(akRaise, 14)
    expect CosinoError:
      sim.act(akRaise, 15)       # increment 1 < 6 and not an all-in
    sim.act(akFold)
    sim.act(akCall)

  test "bets below the big blind are rejected":
    var sim = fixtureConfig(vHoldem, 2).freshHand()
    sim.act(akCall)
    sim.act(akCheck)
    expect CosinoError:
      sim.act(akBet, 1)
    sim.act(akBet, 2)
    check sim.currentBet == 2

  test "a short all-in raise does not reopen the betting":
    ## Stacks reset every hand, so a short stack cannot arise from play; the
    ## engine's short-all-in rule is exercised directly.
    var sim = fixtureConfig(vHoldem, 3).freshHand()
    sim.seats[2].stack = 10      ## bb already posted 2 of its 12
    sim.act(akRaise, 8)          # seat 0 raises to 8
    sim.act(akCall)              # seat 1 calls 8
    sim.act(akRaise, 12)         # bb shoves 12: increment 4 < 6 -> short
    check sim.seats[2].allIn
    check sim.actingSeat == 0
    expect CosinoError:
      sim.act(akRaise, 20)       # betting is closed to seat 0
    sim.act(akCall)
    expect CosinoError:
      sim.act(akRaise, 20)
    sim.act(akCall)

  test "a full raise reopens the betting":
    var sim = fixtureConfig(vHoldem, 3).freshHand()
    sim.act(akRaise, 8)
    sim.act(akRaise, 20)
    sim.act(akFold)
    sim.act(akRaise, 50)
    check sim.currentBet == 50

suite "pots":
  test "the uncalled excess of a shove returns to the bettor":
    var sim = fixtureConfig(vHoldem, 2).freshHand(
      riggedDeck(@["As Ad", "7c 2d"], "Ks Qh 9d 5c 3h"))
    sim.seats[1].stack = 38      ## bb posted 2 of its 40
    sim.act(akRaise, 100)        # sb shoves 100 into a 40 stack
    sim.act(akCall)
    check sim.done
    check sim.seats[0].stack == 140
    check sim.seats[1].stack == 0
    check sim.totalStacks() == 140

  test "side pots pay by commitment level":
    var sim = fixtureConfig(vHoldem, 3).freshHand(
      riggedDeck(@["Ks Kd", "7c 2d", "As Ad"], "Qs Jh 9d 5c 3h"))
    ## button 0 -> sb 1, bb 2, utg 0. Deal order from sb: seats 1, 2, 0.
    sim.seats[0].stack = 10      ## the short stack, holding aces
    sim.seats[1].stack = 49      ## posted 1 of its 50
    sim.act(akRaise, 10)         # utg all-in 10
    sim.act(akRaise, 50)         # sb shoves 50
    sim.act(akCall)              # bb calls 50
    check sim.done
    check sim.seats[0].stack == 30    ## main pot 30 to the aces
    check sim.seats[1].stack == 80    ## side pot 80 to the kings
    check sim.seats[2].stack == 50
    check sim.totalStacks() == 160

  test "split pots share evenly with the odd chip clockwise of the button":
    var sim = fixtureConfig(vHoldem, 3).freshHand(
      riggedDeck(@["2c 2d", "3c 3d", "Ks Kd"], "4s 5h 6d 7c 8h"))
    sim.act(akRaise, 11)
    sim.act(akCall)
    sim.act(akCall)
    for street in 0 ..< 3:
      for live in 0 ..< 3:
        sim.act(akCheck)
    check sim.done
    check sim.seats[0].stack == 100
    check sim.seats[1].stack == 100
    check sim.seats[2].stack == 100

  test "an odd chip goes to the first winner past the button at hold'em":
    var config = fixtureConfig(vHoldem, 2)
    config.bigBlind = 3
    var sim = config.freshHand(
      riggedDeck(@["2c 2d", "2h 2s"], "4s 5h 6d 7c 8h"))
    check sim.oddChipFirst() == sim.order[1]
    sim.act(akCall)
    sim.act(akCheck)
    for street in 0 ..< 3:
      sim.act(akCheck)
      sim.act(akCheck)
    check sim.done
    check sim.seats[0].stack == 100
    check sim.seats[1].stack == 100

# ---- Kuhn -------------------------------------------------------------------

suite "kuhn rules":
  test "all five legal sequences produce the documented net":
    ## Deck order is deal order: position 0 then position 1. King to
    ## position 0, jack to position 1, so position 0 always wins a showdown.
    let deck = @[47, 39, 43]     ## Ks, Js, Qs
    proc runSequence(actions: seq[(ActionKind, int)]): seq[int] =
      let config = fixtureConfig(vKuhn, 2)
      var sim = config.freshHand(deck)
      for (kind, amount) in actions:
        sim.act(kind, amount)
      check sim.done
      for seat in sim.seats:
        result.add(seat.stack - config.startingStack)
    ## pp -> showdown for the 2-chip pot: +/-1
    check runSequence(@[(akCheck, 0), (akCheck, 0)]) == @[1, -1]
    ## pbp -> the bettor takes the 2-chip pot uncontested: +/-1
    check runSequence(@[(akCheck, 0), (akBet, 1), (akFold, 0)]) == @[-1, 1]
    ## pbb -> showdown for the 4-chip pot: +/-2
    check runSequence(@[(akCheck, 0), (akBet, 1), (akCall, 0)]) == @[2, -2]
    ## bp -> the bettor takes the 2-chip pot: +/-1
    check runSequence(@[(akBet, 1), (akFold, 0)]) == @[1, -1]
    ## bb -> showdown for the 4-chip pot: +/-2
    check runSequence(@[(akBet, 1), (akCall, 0)]) == @[2, -2]

  test "the higher card always wins the showdown":
    for (a, b, winner) in [(47, 39, 0), (39, 47, 1), (43, 39, 0),
        (39, 43, 1), (47, 43, 0), (43, 47, 1)]:
      let config = fixtureConfig(vKuhn, 2)
      var sim = config.freshHand(@[a, b, 43])
      sim.act(akCheck)
      sim.act(akCheck)
      check sim.done
      check sim.seats[winner].stack == config.startingStack + 1
      check sim.seats[1 - winner].stack == config.startingStack - 1

  test "the wager cap rejects a raise":
    var sim = fixtureConfig(vKuhn, 2).freshHand(@[47, 39, 43])
    sim.act(akBet, 1)
    check sim.wagerCapReached()
    check not sim.canRaise(sim.actingSeat)
    expect CosinoError:
      sim.act(akRaise, 2)
    expect CosinoError:
      sim.act(akBet, 1)
    sim.act(akCall)
    check sim.done

  test "position 0 acts first and the ante is dead money":
    let sim = fixtureConfig(vKuhn, 2, seatOrder = @[1, 0]).freshHand(
      @[47, 39, 43])
    check sim.actingSeat == 1            ## slot 1 sits at position 0
    check sim.pot == 2
    check sim.currentBet == 0
    check sim.callAmount(sim.actingSeat) == 0
    check sim.seats[0].holeCards == @[39]
    check sim.seats[1].holeCards == @[47]

# ---- Leduc ------------------------------------------------------------------

suite "leduc rules":
  test "wager sizes are 2 then 4 with a cap of two wagers per round":
    ## Deal: position 0 gets Ks, position 1 gets Js; board Qs.
    var sim = fixtureConfig(vLeduc, 2).freshHand(@[47, 39, 43, 38, 42, 46])
    check sim.pot == 2
    sim.act(akBet, 99)                  ## the amount is ignored: fixed at 2
    check sim.currentBet == 2
    sim.act(akRaise, 99)
    check sim.currentBet == 4
    check sim.wagerCapReached()
    expect CosinoError:
      sim.act(akRaise, 6)
    sim.act(akCall)
    ## Round 1 closed: the board card comes and the wager doubles to 4.
    check sim.board == @[43]
    check sim.round == 1
    check sim.wagerSize() == 4
    check sim.actingSeat == sim.order[0]
    sim.act(akBet, 0)
    check sim.currentBet == 4
    sim.act(akRaise, 0)
    check sim.currentBet == 8

  test "the board card comes only when both seats are live":
    var sim = fixtureConfig(vLeduc, 2).freshHand(@[47, 39, 43, 38, 42, 46])
    sim.act(akBet, 0)
    sim.act(akFold)
    check sim.done
    check sim.board.len == 0

  test "a pair beats an unpaired king":
    ## Position 0 holds Js, position 1 holds Ks, board Jh: the jack pairs.
    let config = fixtureConfig(vLeduc, 2)
    var sim = config.freshHand(@[39, 47, 38, 43, 42, 46])
    sim.act(akCheck)
    sim.act(akCheck)
    check sim.board == @[38]
    sim.act(akCheck)
    sim.act(akCheck)
    check sim.done
    check sim.seats[0].stack == config.startingStack + 1
    check sim.seats[1].stack == config.startingStack - 1

  test "equal ranks split, and the odd chip belongs to position 0":
    let config = fixtureConfig(vLeduc, 2, seatOrder = @[1, 0])
    ## Both seats hold a queen; the board is a king. Dead heat.
    var sim = config.freshHand(@[43, 42, 47, 39, 38, 46])
    check sim.oddChipFirst() == sim.order[0]
    check sim.oddChipFirst() == 1
    sim.act(akCheck)
    sim.act(akCheck)
    sim.act(akCheck)
    sim.act(akCheck)
    check sim.done
    check sim.seats[0].stack == config.startingStack
    check sim.seats[1].stack == config.startingStack

  test "folding forfeits the whole commitment":
    let config = fixtureConfig(vLeduc, 2)
    var sim = config.freshHand(@[47, 39, 43, 38, 42, 46])
    sim.act(akBet, 0)                     ## position 0 bets 2
    sim.act(akRaise, 0)                   ## position 1 raises to 4
    sim.act(akFold)                       ## position 0 forfeits 3
    check sim.done
    check sim.seats[0].stack == config.startingStack - 3
    check sim.seats[1].stack == config.startingStack + 3

# ---- The one rule change: no busts, stacks reset ----------------------------

suite "per-hand reset":
  test "every hand begins with every seat on the starting stack":
    for variant in [vKuhn, vLeduc, vHoldem]:
      let seats = if variant == vHoldem: 4 else: 2
      var config = fixtureConfig(variant, seats, hands = 6, duplicate = true)
      var match = initMatch(config)
      var seen = 0
      while not match.done:
        for seat in match.sim.seats:
          check seat.stack + seat.totalCommitted == config.startingStack
        inc seen
        playScriptedHand(match)
      check seen == config.hands

  test "a seat that loses everything is back in full next hand":
    var config = fixtureConfig(vHoldem, 2, hands = 4)
    var sim = config.freshHand(riggedDeck(@["As Ad", "7c 2d"],
      "Ks Qh 9d 5c 3h"))
    sim.act(akRaise, 100)
    sim.act(akCall)
    check sim.done
    check sim.seats[1].stack == 0
    var stackOffs = 0
    for event in sim.events:
      if event.kind == evStackOff:
        check event.seat == 1
        inc stackOffs
    check stackOffs == 1
    ## The very next hand deals it a full stack again.
    let next = config.freshHand(hand = 1)
    for seat in next.seats:
      check seat.stack + seat.totalCommitted == config.startingStack

# ---- Duplicate decks and seating -------------------------------------------

suite "duplicate mirror":
  test "the pair shares one deck and the mirror rotates by n div 2":
    for (variant, n) in [(vKuhn, 2), (vLeduc, 2), (vHoldem, 2), (vHoldem, 6)]:
      var config = fixtureConfig(variant, n, hands = 4, duplicate = true)
      config.seed = 31337
      config.randomiseSeating = true
      config.seatOrder = config.seatOrderFor()
      let base = config.freshHand(hand = 0)
      let mirror = config.freshHand(hand = 1)
      check base.pair == 0
      check mirror.pair == 0
      check not base.mirror
      check mirror.mirror
      ## The same shuffled deck, dealt by the same procedure.
      check pairDeck(config, 0) == pairDeck(config, 0)
      ## Position p holds the identical cards in both halves of the pair.
      for position in 0 ..< n:
        check base.seats[base.order[position]].holeCards ==
          mirror.seats[mirror.order[position]].holeCards
      ## The position map is seatOrder rotated by n div 2.
      for position in 0 ..< n:
        check mirror.order[position] ==
          config.seatOrder[(position + n div 2) mod n]
      ## And the button does not move: it is always position 0.
      check base.button == base.order[0]
      check mirror.button == mirror.order[0]

  test "heads-up, each seat plays its opponent's cards in the mirror":
    var config = fixtureConfig(vHoldem, 2, hands = 4, duplicate = true)
    config.seed = 909
    config.seatOrder = @[0, 1]
    let base = config.freshHand(hand = 0)
    let mirror = config.freshHand(hand = 1)
    check base.seats[0].holeCards == mirror.seats[1].holeCards
    check base.seats[1].holeCards == mirror.seats[0].holeCards

  test "a new pair draws a new deck":
    var config = fixtureConfig(vHoldem, 2, hands = 4, duplicate = true)
    config.seed = 909
    config.seatOrder = @[0, 1]
    check pairDeck(config, 0) != pairDeck(config, 1)
    check config.freshHand(hand = 0).seats[0].holeCards !=
      config.freshHand(hand = 2).seats[0].holeCards

  test "the mirror is invisible to the seats":
    ## A seat's observation is built from THIS hand's events only, so the
    ## prompt cannot carry a cross-hand card transcript.
    var config = fixtureConfig(vHoldem, 2, hands = 4, duplicate = true)
    config.seed = 909
    var match = initMatch(config)
    let baseCards = cardsText(match.sim.seats[0].holeCards)
    playScriptedHand(match)
    check match.sim.hand == 1
    check match.sim.mirror
    let prompt = userPrompt(match.sim, match.sim.actingSeat, "", "")
    ## The observation is rebuilt from THIS hand's events only: no previous
    ## hand's header, no card transcript, and no word for the pairing.
    check prompt.contains("Hand 2 begins")
    check not prompt.contains("Hand 1 begins")
    check not prompt.toLowerAscii().contains("mirror")
    check not prompt.toLowerAscii().contains("duplicate")
    ## The seat is shown its OWN cards, which in the mirror are the ones its
    ## counterpart held -- but nothing says so.
    let mine = cardsText(match.sim.seats[match.sim.actingSeat].holeCards)
    check prompt.contains(mine)
    let opponent = 1 - match.sim.actingSeat
    check not prompt.contains(
      cardsText(match.sim.seats[opponent].holeCards))
    check baseCards.len > 0

suite "seat randomisation":
  test "seatOrder is a deterministic permutation of the slots":
    for seats in 2 .. 6:
      for seed in [1, 7, 42, 2026]:
        var config = fixtureConfig(vHoldem, seats)
        config.seed = seed
        config.randomiseSeating = true
        let order = config.seatOrderFor()
        check order.len == seats
        check order.sorted() == toSeq(0 ..< seats)
        check order == config.seatOrderFor()

  test "results arrays are indexed by SLOT whatever the seating":
    var config = fixtureConfig(vHoldem, 4, hands = 4, duplicate = true)
    config.seed = 5150
    config.randomiseSeating = true
    var match = initMatch(config)
    check match.config.seatOrder.len == 4
    playScripted(match)
    match.finishMatch()
    let results = match.resultsJson()
    for index, node in results["names"].getElems():
      check node.getStr() == config.players[index].name
    check results["seatOrder"].len == 4
    check results["net"].len == 4

# ---- Chips and scores -------------------------------------------------------

suite "chip conservation fuzz":
  test "200 random legal matches per variant conserve chips and replay":
    var rng = initRand(99)
    for (variant, seatChoices) in [(vKuhn, @[2]), (vLeduc, @[2]),
        (vHoldem, @[2, 3, 4, 5, 6])]:
      for round in 0 ..< 200:
        let seats = seatChoices[rng.rand(seatChoices.high)]
        var config = fixtureConfig(variant, seats, hands = 2 + 2 * rng.rand(2),
          duplicate = true)
        config.seed = rng.rand(100_000)
        config.randomiseSeating = true
        var match = initMatch(config)
        let chips = seats * config.startingStack
        while not match.done:
          while not match.sim.done:
            let seat = match.sim.actingSeat
            check seat >= 0
            var choices: seq[PlayerAction]
            if match.sim.callAmount(seat) == 0:
              choices.add(PlayerAction(kind: akCheck))
            else:
              choices.add(PlayerAction(kind: akCall))
              choices.add(PlayerAction(kind: akFold))
            if match.sim.canBet(seat):
              choices.add(PlayerAction(kind: akBet,
                amount: min(match.sim.minBet(seat) + rng.rand(10),
                  match.sim.maxRaiseTo(seat))))
            elif match.sim.canRaise(seat):
              let lo = match.sim.minRaiseTo(seat)
              let hi = match.sim.maxRaiseTo(seat)
              var to = min(lo + rng.rand(6), hi)
              if to > match.sim.currentBet:
                choices.add(PlayerAction(kind: akRaise, amount: to))
            match.sim.applyAction(seat, choices[rng.rand(choices.high)])
          var onTable = 0
          for seat in match.sim.seats:
            onTable += seat.stack
          check onTable == chips
          match.finishHand()
          if not match.done:
            match.nextHand()
        ## Zero-sum, exactly.
        var netSum = 0
        for value in match.net:
          netSum += value
        check netSum == 0
        ## And the replay re-derives the same table.
        let frames = replayMatch(config, match.allEvents())
        check frames.len == match.allEvents().len + 1
        for index, seat in match.sim.seats:
          check frames[^1].seats[index].stack == seat.stack

suite "scoring":
  test "scores sum to 1, sit in [0,1], and break-even is exactly 1/n":
    for (variant, seats) in [(vKuhn, 2), (vLeduc, 2), (vHoldem, 2),
        (vHoldem, 6)]:
      var config = fixtureConfig(variant, seats, hands = 6, duplicate = true)
      config.seed = 4711
      var match = initMatch(config)
      playScripted(match)
      match.finishMatch()
      let results = match.resultsJson()
      var total = 0.0
      for score in results["scores"]:
        total += score.getFloat()
        check score.getFloat() >= 0.0
        check score.getFloat() <= 1.0
      check abs(total - 1.0) < 1e-9
      for index, node in results["net"].getElems():
        if node.getInt() == 0:
          check abs(results["scores"][index].getFloat() -
            1.0 / seats.float) < 1e-12

  test "winning every chip in every hand scores exactly 1.0":
    ## The scoring layer, driven straight from a recorded log.
    var config = fixtureConfig(vHoldem, 2, hands = 4)
    let stack = config.startingStack
    let hands = 4
    var events: seq[GameEvent]
    for hand in 0 ..< hands:
      events.add(GameEvent(kind: evHandStart, hand: hand, seat: 0,
        stackAfter: -1, betAfter: -1, potAfter: 0, pair: hand div 2))
      events.add(GameEvent(kind: evHandEnd, hand: hand, seat: -1,
        stackAfter: -1, betAfter: -1, potAfter: 0, pair: -1,
        data: %*{"net": [stack * (hand + 1), -stack * (hand + 1)]}))
    events.add(GameEvent(kind: evMatchEnd, hand: hands - 1, seat: -1,
      stackAfter: -1, betAfter: -1, potAfter: -1, pair: -1,
      data: %*{"reason": "complete", "handsScored": hands, "seed": 0}))
    let results = resultsFromEvents(config, events)
    check abs(results["scores"][0].getFloat() - 1.0) < 1e-12
    check abs(results["scores"][1].getFloat() - 0.0) < 1e-12
    check results["win"].getElems() == @[%true, %false]
    check results["netPerHand"][0].getFloat() == stack.float
    check results["unitsPerHand"][0].getFloat() ==
      stack.float / config.bigBlind.float

proc jsonOf(events: seq[GameEvent]): JsonNode =
  result = newJArray()
  for event in events:
    result.add(event.eventToJson())

proc roundTrip(events: seq[GameEvent]): seq[GameEvent] =
  for node in parseJson($jsonOf(events)):
    result.add(eventFromJson(node))

# ---- The committed six-max audit fixture ------------------------------------

const FixturePath = currentSourcePath().parentDir().parentDir() /
  "tools" / "ci" / "fixtures" / "sixmax_audit.replay"
const ChipRaceFixturePath = currentSourcePath().parentDir().parentDir() /
  "tools" / "ci" / "fixtures" / "chiprace_bust.replay"

proc fixtureSay(seat: int): string =
  ## Exactly MaxSayLen runes of multi-byte text, and NOT the ellipsis
  ## `truncateRunes` leaves behind: a remark the server passed at full length
  ## is the worst case the speech bubble has to render whole, so the viewer
  ## smoke can count every drawn ellipsis as a defect.
  let body = ("\u{1F0A1}\u00e9\u4f60 seat " & $seat & " ").repeat(60)
  $body.toRunes()[0 ..< MaxSayLen]

proc buildSixMaxFixture(): string =
  ## A six-max Hold'em replay with TWO flagged pairs and a full-cap `say` on
  ## every seat. The cert fixture is a two-seat Kuhn episode, which leaves the
  ## sixth plate, the audit card and the worst-case bubble text undrawn by
  ## anything in CI (cogchemists, 2026-08-24).
  var config = defaultGameConfig()
  config.variantDefaults(vHoldem)
  config.seed = 4242
  config.hands = 12
  config.duplicate = true
  config.randomiseSeating = true
  config.sampled = true
  for index in 0 ..< 6:
    config.players.add(PlayerConfig(name: "cosino-fixture-" & $index))
    config.tokens.add("t" & $index)
  var match = initMatch(config)
  var spoken = newSeq[bool](6)
  while not match.done:
    ## Hands 0-5: slot 2 dumps to slot 5. Hands 6-11: slot 1 dumps to slot 4.
    let (dumper, partner) = if match.sim.hand < 6: (2, 5) else: (1, 4)
    while not match.sim.done:
      let seat = match.sim.actingSeat
      let s = match.sim
      if not spoken[seat]:
        spoken[seat] = true
        match.sim.recordSay(seat, fixtureSay(seat))
      var act: PlayerAction
      if seat == dumper:
        if s.street == stPreflop:
          act =
            if s.canRaise(seat):
              PlayerAction(kind: akRaise, amount: min(20, s.maxRaiseTo(seat)))
            elif s.callAmount(seat) > 0: PlayerAction(kind: akCall)
            else: PlayerAction(kind: akCheck)
        elif s.street == stFlop:
          act =
            if s.canBet(seat):
              PlayerAction(kind: akBet, amount: min(20, s.maxRaiseTo(seat)))
            elif s.callAmount(seat) > 0: PlayerAction(kind: akCall)
            else: PlayerAction(kind: akCheck)
        elif s.street == stRiver and s.callAmount(seat) > 0:
          act = PlayerAction(kind: akFold)
        else:
          act =
            if s.callAmount(seat) > 0: PlayerAction(kind: akCall)
            else: PlayerAction(kind: akCheck)
      elif seat == partner:
        if s.street == stRiver and s.canBet(seat):
          act = PlayerAction(kind: akBet, amount: s.minBet(seat))
        else:
          act =
            if s.callAmount(seat) > 0: PlayerAction(kind: akCall)
            else: PlayerAction(kind: akCheck)
      else:
        act =
          if s.callAmount(seat) > 0: PlayerAction(kind: akFold)
          else: PlayerAction(kind: akCheck)
      match.sim.applyAction(seat, act)
    match.finishHand()
    if not match.done:
      match.nextHand()
  match.finishMatch()
  var names = newJArray()
  var policyNames = newJArray()
  for index, seat in match.sim.seats:
    names.add(%seat.name)
    policyNames.add(%config.players[index].name)
  $ %*{
    "protocol": "cosino.replay.v1",
    "names": names,
    "policyNames": policyNames,
    "config": replayConfigJson(match.config),
    "events": jsonOf(match.allEvents()),
    "results": match.resultsJson()
  } & "\n"

# ---- Recording and re-derivation -------------------------------------------

suite "record then re-derive":
  test "every end reason re-derives byte-identically":
    for reason in [erComplete, erDeadline, erBudget]:
      var config = fixtureConfig(vKuhn, 2, hands = 8, duplicate = true)
      config.seed = 20260826
      var match = initMatch(config)
      case reason
      of erComplete:
        playScripted(match)
      of erBudget:
        playScriptedHand(match)
        playScriptedHand(match)
        match.endMatchEarly(erBudget)
      of erDeadline:
        ## The HARD guard: a live hand is abandoned and every chip refunded.
        playScriptedHand(match)
        playScriptedHand(match)
        check not match.sim.done
        let before = match.handsScored
        match.voidLiveHand()
        check match.handsScored == before
        match.endMatchEarly(erDeadline)
      match.finishMatch()
      let served = match.resultsJson()
      check served["reason"].getStr() == $reason

      let events = match.allEvents()
      let back = roundTrip(events)
      check back.len == events.len
      ## The state timeline is byte-identical through the replay bytes.
      check $statesFromEvents(config, events) ==
        $statesFromEvents(config, back)
      ## And so is every platform-facing number.
      let derived = resultsFromEvents(config, back)
      for key in ["names", "scores", "win", "net", "netPerHand",
          "unitsPerHand", "handsWon", "stackOffs", "exploitability",
          "exploitabilityCoverage", "exploitabilityFill", "audit", "variant",
          "handsPlayed", "handsScored", "pairsComplete", "unpairedHands",
          "seed", "reason"]:
        check $derived[key] == $served[key]
      ## A voided hand is refunded, not scored, and the nets still sum to 0.
      var netSum = 0
      for value in derived["net"]:
        netSum += value.getInt()
      check netSum == 0
      if reason == erDeadline:
        var voids = 0
        for event in back:
          if event.kind == evHandVoid:
            inc voids
            var refunded = 0
            for value in event.data["refunds"]:
              refunded += value.getInt()
            check refunded > 0
        check voids == 1
        check derived["handsPlayed"].getInt() ==
          derived["handsScored"].getInt() + 1

  test "matchEnd is the last event and carries the stop as a recorded fact":
    var config = fixtureConfig(vLeduc, 2, hands = 4, duplicate = true)
    config.seed = 77
    var match = initMatch(config)
    playScripted(match)
    match.finishMatch()
    let events = match.allEvents()
    check events[^1].kind == evMatchEnd
    check events[^1].data["reason"].getStr() == "complete"
    check events[^1].data["handsScored"].getInt() == match.handsScored
    check events[^1].data["seed"].getInt() == config.seed
    ## Idempotent: a second call cannot double the tail.
    let before = match.allEvents().len
    match.finishMatch()
    check match.allEvents().len == before

  test "events round-trip through JSON for every kind in the vocabulary":
    var seen: set[EventKind]
    for (variant, seats) in [(vKuhn, 2), (vLeduc, 2), (vHoldem, 6)]:
      var config = fixtureConfig(variant, seats, hands = 6, duplicate = true)
      config.seed = 606
      var match = initMatch(config)
      playScriptedHand(match)
      ## Force a stack-off and a void so both kinds appear.
      if variant == vHoldem:
        while not match.sim.done:
          let seat = match.sim.actingSeat
          if match.sim.canBet(seat):
            match.sim.act(akBet, match.sim.maxRaiseTo(seat))
          elif match.sim.canRaise(seat):
            match.sim.act(akRaise, match.sim.maxRaiseTo(seat))
          elif match.sim.callAmount(seat) > 0:
            match.sim.act(akCall)
          else:
            match.sim.act(akCheck)
        match.finishHand()
        if not match.done:
          match.nextHand()
      match.sim.recordSay(match.sim.actingSeat, "nice hand")
      match.voidLiveHand()
      match.endMatchEarly(erDeadline)
      match.finishMatch()
      let events = match.allEvents()
      for event in events:
        seen.incl(event.kind)
        check eventFromJson(event.eventToJson()) == event
    ## The chip race is the only source of `bust`: a rigged cooler felts one
    ## seat on the first hand.
    var raceConfig = fixtureConfig(vHoldem, 2, hands = 4)
    raceConfig.chipRace = true
    var race = Match(config: raceConfig, names: raceConfig.names,
      net: newSeq[int](2), handsWon: newSeq[int](2),
      stackOffs: newSeq[int](2),
      sim: initHand(raceConfig, 0, raceConfig.names, @[0, 0], @[0, 0],
        riggedDeck(@["As Ad", "7c 2d"], "Ks Qh 9d 5c 3h"),
        stacks = @[100, 100], button = 0))
    race.sim.act(akRaise, 100)
    race.sim.act(akCall)
    race.finishHand()
    race.finishMatch()
    for event in race.allEvents():
      seen.incl(event.kind)
      check eventFromJson(event.eventToJson()) == event
    ## `audit` only exists where collusion was found, so fold the flagged
    ## six-max fixture in: it is a real replay of this game too.
    for node in parseJson(buildSixMaxFixture())["events"]:
      let event = eventFromJson(node)
      seen.incl(event.kind)
      check eventFromJson(event.eventToJson()) == event
    for kind in EventKind:
      check kind in seen

# ---- The chip race (cosino's classic table) ---------------------------------

proc chipRaceConfig(players: int, hands = 8, seed = 0): GameConfig =
  result = fixtureConfig(vHoldem, players, hands = hands)
  result.chipRace = true
  result.seed = seed

proc raceMatch(config: GameConfig, stacks: seq[int], button: int,
    deck: seq[int]): Match =
  ## A Match around one rigged chip-race hand.
  let n = config.players.len
  Match(config: config, names: config.names,
    net: newSeq[int](n), handsWon: newSeq[int](n), stackOffs: newSeq[int](n),
    sim: initHand(config, 0, config.names, newSeq[int](n), newSeq[int](n),
      deck, stacks = stacks, button = button))

suite "chip race":
  test "stacks carry and the button walks":
    var match = initMatch(chipRaceConfig(3))
    check match.sim.button == 0
    ## Fold the first hand out: UTG (the button, three-handed) then the sb.
    match.sim.act(akFold)
    match.sim.act(akFold)
    match.finishHand()
    check match.handsPlayed == 1
    check not match.done
    match.nextHand()
    check match.sim.button == 1
    check match.sim.hand == 1
    ## The big blind of hand 0 kept the sb's chip: stacks carried.
    check match.sim.seats[2].stack + match.sim.seats[2].committed == 101
    check match.sim.seats[1].stack + match.sim.seats[1].committed == 99
    ## Carried net rides on the seats for the standings.
    check match.sim.seats[1].net == -1

  test "a felted table ends the match before the hand limit":
    var match = raceMatch(chipRaceConfig(2, hands = 30), @[100, 100], 0,
      riggedDeck(@["As Ad", "7c 2d"], "Ks Qh 9d 5c 3h"))
    match.sim.act(akRaise, 100)
    match.sim.act(akCall)
    check match.sim.done
    check match.sim.seats[1].stack == 0
    check match.sim.seats[1].isOut
    var busts = 0
    for event in match.sim.events:
      if event.kind == evBust:
        inc busts
    check busts == 1
    match.finishHand()
    check match.done
    expect CosinoError:
      match.nextHand()

  test "busted seats sit out and the button skips them":
    var match = raceMatch(chipRaceConfig(3), @[100, 190, 10], 0,
      riggedDeck(@["Ks Kd", "7c 2d", "As Ad"], "Qs Jh 9d 5c 3h"))
    ## Deal order from the sb: seat 1 kings, seat 2 junk, seat 0 aces.
    ## Seat 2 (bb, 7-2) calls a shove and busts.
    match.sim.act(akFold)        # utg 0
    match.sim.act(akRaise, 190)  # sb 1 shoves kings
    match.sim.act(akCall)        # bb 2 calls its last 10 with junk
    check match.sim.done
    check match.sim.seats[2].isOut
    match.finishHand()
    check not match.done
    match.nextHand()
    ## Button was 0; the next funded seat clockwise is 1.
    check match.sim.button == 1
    check match.sim.seats[2].isOut
    check match.sim.seats[2].holeCards.len == 0
    ## Two funded seats play heads-up: the button posts the small blind.
    check match.sim.sbSeat == 1
    check match.sim.bbSeat == 0

  test "chip-race results are chip shares that re-derive from the replay":
    var config = chipRaceConfig(4, hands = 6, seed = 11)
    var match = initMatch(config)
    playScripted(match)
    match.finishMatch()
    let results = match.resultsJson()
    check results["chipRace"].getBool()
    let n = 4
    var total = 0.0
    var chips = 0
    for index in 0 ..< n:
      let stack = results["stacks"][index].getInt()
      chips += stack
      total += results["scores"][index].getFloat()
      ## The chip share IS the score.
      check abs(results["scores"][index].getFloat() -
        stack / (n * config.startingStack)) < 1e-9
      check results["busted"][index].getBool() == (stack == 0)
      check results["net"][index].getInt() ==
        stack - config.startingStack
    ## No chip evaporates and the shares sum to exactly one.
    check chips == n * config.startingStack
    check abs(total - 1.0) < 1e-9
    ## The replay's last frame carries the same final stacks.
    let frames = replayMatch(match.config, match.allEvents())
    for index in 0 ..< n:
      check frames[^1].seats[index].stack ==
        results["stacks"][index].getInt()
      check frames[^1].seats[index].isOut ==
        results["busted"][index].getBool()

  test "a voided chip-race hand refunds the carried stacks":
    var match = raceMatch(chipRaceConfig(2, hands = 8), @[60, 140], 0,
      riggedDeck(@["As Ad", "7c 2d"], "Ks Qh 9d 5c 3h"))
    match.sim.act(akRaise, 30)
    match.sim.act(akCall)
    match.voidLiveHand()
    check match.sim.seats[0].stack == 60
    check match.sim.seats[1].stack == 140
    check match.handsScored == 0

# ---- Budget fitting ---------------------------------------------------------

suite "budget fit":
  test "sampleEpisode is idempotent, always even, and caps each variant":
    for (variant, seats, cap) in [(vKuhn, 2, 84), (vLeduc, 2, 40),
        (vHoldem, 2, 36), (vHoldem, 6, 16)]:
      var config = fixtureConfig(variant, seats, hands = 500,
        duplicate = true)
      config.sampled = false
      check config.handCap() == cap
      let drawn = sampleEpisode(config)
      check drawn.hands <= cap
      check drawn.hands mod 2 == 0
      check drawn.hands >= MinHands
      check sampleEpisode(drawn).hands == drawn.hands
      check sampleEpisode(drawn).sampled
      ## An already-small hand count is left alone (rounded down to even).
      var small = config
      small.hands = 7
      small.sampled = false
      check sampleEpisode(small).hands == 6

  test "the chip race caps to the budget but never rounds to pairs":
    var config = fixtureConfig(vHoldem, 2, hands = 7)
    config.chipRace = true
    config.sampled = false
    check sampleEpisode(config).hands == 7
    config.hands = 500
    check sampleEpisode(config).hands == 36

  test "the declared variant hand counts all fit the budget":
    for (variant, seats, hands) in [(vKuhn, 2, 60), (vLeduc, 2, 36),
        (vHoldem, 2, 30), (vHoldem, 6, 14)]:
      var config = fixtureConfig(variant, seats, hands = hands)
      config.sampled = false
      check sampleEpisode(config).hands == hands

# ---- Rune truncation into the replay ---------------------------------------

suite "rune truncation in the replay":
  test "the recorded say is rune-capped and the replay parses strictly":
    var config = fixtureConfig(vHoldem, 3, hands = 2)
    var match = initMatch(config)
    let hostile = "\u{1F0A1}".repeat(900)
    match.sim.recordSay(match.sim.actingSeat, hostile)
    playScripted(match)
    match.finishMatch()
    let wire = $ %*{
      "protocol": "cosino.replay.v1",
      "config": replayConfigJson(config),
      "events": jsonOf(match.allEvents()),
      "results": match.resultsJson()
    }
    check wire.validateUtf8() == -1
    let parsed = parseJson(wire)
    for event in parsed["events"]:
      if event{"kind"}.getStr() == "say":
        check event["text"].getStr().runeLen <= MaxSayLen
        check event["text"].getStr().validateUtf8() == -1

suite "the committed six-max audit fixture":
  test "regenerates byte-identically to tools/ci/fixtures/sixmax_audit.replay":
    let generated = buildSixMaxFixture()
    let payload = parseJson(generated)
    ## It is a real, current-format replay of this game.
    check payload["protocol"].getStr() == "cosino.replay.v1"
    check payload["config"]["seats"].getInt() == 6
    check payload["config"]["gameVersion"].getInt() == GameVersion
    check payload["results"]["audit"]["flagged"].len == 2
    var withSay: set[0 .. 5]
    for event in payload["events"]:
      if event{"kind"}.getStr() == "say":
        check event["text"].getStr().runeLen == MaxSayLen
        withSay.incl(event["seat"].getInt())
    check withSay == {0 .. 5}
    check generated.validateUtf8() == -1

    if not fileExists(FixturePath) or readFile(FixturePath) != generated:
      ## Never let the committed fixture drift from the writer: rewrite it and
      ## fail, so the regenerated bytes are what gets committed.
      createDir(FixturePath.parentDir())
      writeFile(FixturePath, generated)
      checkpoint("regenerated " & FixturePath & " -- commit the new bytes")
      fail()

# ---- The committed chip-race fixture ----------------------------------------

proc buildChipRaceFixture(): string =
  ## A six-max CHIP RACE where every seat jams every hand: busts land within a
  ## few hands, the button walks over dead seats, and the endcard shows the
  ## chip-share standings. Nothing else in CI draws a toppled cog, a BUST
  ## label, a bust beat or the chip-race endcard columns.
  var config = defaultGameConfig()
  config.variantDefaults(vHoldem)
  config.chipRace = true
  config.duplicate = false
  config.randomiseSeating = false
  config.seed = 99
  config.hands = 16
  config.sampled = true
  for index in 0 ..< 6:
    config.players.add(PlayerConfig(name: "cosino-fixture-" & $index))
    config.tokens.add("t" & $index)
  var match = initMatch(config)
  var spoken = newSeq[bool](6)
  while not match.done:
    while not match.sim.done:
      let seat = match.sim.actingSeat
      let s = match.sim
      if not spoken[seat]:
        spoken[seat] = true
        match.sim.recordSay(seat, fixtureSay(seat))
      ## One pairwise war per hand -- the designated jammer shoves, the next
      ## seat calls it off, everyone else folds. Busts trickle in over several
      ## hands, so the replay shows carried stacks and the walking button; a
      ## hand whose jammer is already busted simply folds around.
      let jammer = s.hand mod 6
      let caller = (s.hand + 1) mod 6
      var act: PlayerAction
      if seat == jammer and s.canRaise(seat):
        act = PlayerAction(kind: akRaise, amount: s.maxRaiseTo(seat))
      elif seat == jammer and s.canBet(seat):
        act = PlayerAction(kind: akBet, amount: s.maxRaiseTo(seat))
      elif s.callAmount(seat) > 0:
        act =
          if seat == caller: PlayerAction(kind: akCall)
          else: PlayerAction(kind: akFold)
      else:
        act = PlayerAction(kind: akCheck)
      match.sim.applyAction(seat, act)
    match.finishHand()
    if not match.done:
      match.nextHand()
  match.finishMatch()
  var names = newJArray()
  var policyNames = newJArray()
  for index, seat in match.sim.seats:
    names.add(%seat.name)
    policyNames.add(%config.players[index].name)
  $ %*{
    "protocol": "cosino.replay.v1",
    "names": names,
    "policyNames": policyNames,
    "config": replayConfigJson(match.config),
    "events": jsonOf(match.allEvents()),
    "results": match.resultsJson()
  } & "\n"

suite "the committed chip-race fixture":
  test "regenerates byte-identically to tools/ci/fixtures/chiprace_bust.replay":
    let generated = buildChipRaceFixture()
    let payload = parseJson(generated)
    check payload["protocol"].getStr() == "cosino.replay.v1"
    check payload["config"]["chipRace"].getBool()
    check payload["config"]["gameVersion"].getInt() == GameVersion
    ## The whole point of the fixture: real busts, a real early finish.
    var busts = 0
    for event in payload["events"]:
      if event{"kind"}.getStr() == "bust":
        inc busts
    check busts >= 3
    var bustedFlags = 0
    for flag in payload["results"]["busted"]:
      if flag.getBool():
        inc bustedFlags
    check bustedFlags == busts
    ## One cog holds every chip; the shares still sum to exactly one.
    var total = 0.0
    for score in payload["results"]["scores"]:
      total += score.getFloat()
    check abs(total - 1.0) < 1e-9
    check generated.validateUtf8() == -1

    if not fileExists(ChipRaceFixturePath) or
        readFile(ChipRaceFixturePath) != generated:
      createDir(ChipRaceFixturePath.parentDir())
      writeFile(ChipRaceFixturePath, generated)
      checkpoint("regenerated " & ChipRaceFixturePath &
        " -- commit the new bytes")
      fail()
