import std/[json, random, sequtils, unittest]
import cosino/sim

proc fixtureConfig(players: int, stack = 100, sb = 1, bb = 2,
    hands = 30): GameConfig =
  result = defaultGameConfig()
  result.startingStack = stack
  result.smallBlind = sb
  result.bigBlind = bb
  result.hands = hands
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< players:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc names(config: GameConfig): seq[string] =
  tableNames(config.players, config.seed)

proc freshHand(config: GameConfig, button = 0,
    deck: seq[int] = @[]): Sim =
  var stacks = newSeq[int](config.players.len)
  for index in 0 ..< stacks.len:
    stacks[index] = config.startingStack
  initHand(config, 0, button, stacks, newSeq[int](stacks.len),
    config.names, deck)

proc act(sim: var Sim, kind: ActionKind, amount = 0) =
  sim.applyAction(sim.actingSeat, PlayerAction(kind: kind, amount: amount))

proc riggedDeck(holes: seq[string], board: string): seq[int] =
  ## Hole strings per seat in DEAL order (clockwise from the small blind),
  ## then the board; the rest of the deck is filled with the unused cards.
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

suite "hand evaluator":
  test "category ladder":
    let hands = [
      ("2c 3d 5h 9s Ks", HandHighCard),
      ("2c 2d 5h 9s Ks", HandPair),
      ("2c 2d 5h 5s Ks", HandTwoPair),
      ("2c 2d 2h 9s Ks", HandTrips),
      ("2c 3d 4h 5s 6s", HandStraight),
      ("2s 5s 9s Js Ks", HandFlush),
      ("2c 2d 2h Ks Kd", HandFullHouse),
      ("2c 2d 2h 2s Kd", HandQuads),
      ("2s 3s 4s 5s 6s", HandStraightFlush)
    ]
    for index in 0 ..< hands.len - 1:
      check eval5(parseCards(hands[index][0])) <
        eval5(parseCards(hands[index + 1][0]))
    for (text, category) in hands:
      check handCategory(eval5(parseCards(text))) == category

  test "kickers decide":
    check eval5(parseCards("As Ad 9c 5d 3h")) >
      eval5(parseCards("Ks Kd Qc Jd 9h"))
    check eval5(parseCards("As Ad Kc 5d 3h")) >
      eval5(parseCards("Ah Ac Qc Jd 9h"))
    check eval5(parseCards("As Ks Qs Js 2s")) >
      eval5(parseCards("Ah Kh Qh Th 3h"))

  test "the wheel is the lowest straight":
    let wheel = eval5(parseCards("As 2d 3h 4c 5s"))
    check handCategory(wheel) == HandStraight
    check wheel < eval5(parseCards("2d 3h 4c 5s 6d"))
    ## And an ace-high straight beats a king-high one.
    check eval5(parseCards("Ts Jd Qh Kc As")) >
      eval5(parseCards("9s Td Jh Qc Ks"))

  test "seven cards use the best five":
    ## Pair on board plus a flush in hand: the flush wins out.
    let rank = evalBest(parseCards("Ah Kh 2h 5h 9h 2c 2d"))
    check handCategory(rank) == HandFlush
    ## Board plays: the ace-high straight on board beats two small pairs.
    let boardPlays = evalBest(parseCards("Ts Jd Qh Kc Ad 2c 2d"))
    check handCategory(boardPlays) == HandStraight
    check describeRank(evalBest(parseCards("As Ks Qs Js Ts 2c 3d"))) ==
      "a royal flush"

  test "cards round-trip text":
    for card in 0 ..< 52:
      check parseCard(cardText(card)) == card

suite "blinds and order":
  test "multiway blinds sit clockwise from the button":
    let sim = fixtureConfig(4).freshHand(button = 1)
    check sim.sbSeat == 2
    check sim.bbSeat == 3
    check sim.actingSeat == 0   ## UTG, left of the big blind
    check sim.seats[2].committed == 1
    check sim.seats[3].committed == 2
    check sim.pot == 3

  test "heads-up button posts small and acts first":
    let sim = fixtureConfig(2).freshHand(button = 1)
    check sim.sbSeat == 1
    check sim.bbSeat == 0
    check sim.actingSeat == 1

  test "every seat plays under an anonymous cog alias":
    let config = fixtureConfig(3)
    let sim = config.freshHand()
    for index, seat in sim.seats:
      check seat.name != config.players[index].name
      check seat.name in CogNames

suite "betting":
  test "folding to the big blind pays it the small blind":
    var sim = fixtureConfig(3).freshHand(button = 0)
    sim.act(akFold)          # UTG (button 0 -> sb 1, bb 2, utg 0)
    sim.act(akFold)          # small blind
    check sim.done
    check sim.seats[2].stack == 101   ## bb wins the sb's chip
    check sim.seats[1].stack == 99
    check sim.seats[0].stack == 100
    check sim.totalStacks() == 300

  test "cannot check facing a bet, cannot act out of turn":
    var sim = fixtureConfig(3).freshHand(button = 0)
    expect CosinoError:
      sim.applyAction(1, PlayerAction(kind: akFold))  # not UTG's turn
    expect CosinoError:
      sim.act(akCheck)                                # UTG owes the blind
    sim.act(akCall)
    check sim.seats[0].committed == 2

  test "big blind gets the option and can raise a limped pot":
    var sim = fixtureConfig(3).freshHand(button = 0)
    sim.act(akCall)   # utg limps
    sim.act(akCall)   # sb completes
    check sim.actingSeat == sim.bbSeat
    sim.act(akRaise, 8)
    check sim.currentBet == 8
    check sim.actingSeat == 0   ## back around to UTG

  test "checked-down hand reaches showdown on five board cards":
    var sim = fixtureConfig(2).freshHand(button = 0, deck = riggedDeck(
      @["As Ad", "7c 2d"], "Ks Qh 9d 5c 3h"))
    sim.act(akCall)    # sb completes
    sim.act(akCheck)   # bb option
    for street in 0 ..< 3:
      sim.act(akCheck)
      sim.act(akCheck)
    check sim.done
    check sim.board.len == 5
    ## Button (seat 0) posted sb and was dealt first: aces win.
    check sim.seats[0].stack == 102
    check sim.seats[1].stack == 98

  test "minimum raise rules":
    var sim = fixtureConfig(3).freshHand(button = 0)
    sim.act(akRaise, 8)          # utg raises the 2 blind to 8
    expect CosinoError:
      sim.act(akRaise, 10)       # sb: min raise-to is 14 (increment 6)
    sim.act(akRaise, 14)
    expect CosinoError:
      sim.act(akRaise, 15)       # bb: increment 1 < 6 and not an all-in
    sim.act(akFold)
    sim.act(akCall)              # utg calls the 14

  test "bets below the big blind are rejected":
    var sim = fixtureConfig(2).freshHand(button = 0)
    sim.act(akCall)
    sim.act(akCheck)
    expect CosinoError:
      sim.act(akBet, 1)
    sim.act(akBet, 2)
    check sim.currentBet == 2

  test "a short all-in raise does not reopen the betting":
    var config = fixtureConfig(3)
    var stacks = @[100, 100, 12]
    var sim = initHand(config, 0, 0, stacks, @[0, 0, 0], config.names)
    ## button 0, sb 1, bb 2(stack 12): utg is 0.
    sim.act(akRaise, 8)     # seat 0 raises to 8
    sim.act(akCall)         # seat 1 calls 8
    sim.act(akRaise, 12)    # bb shoves 12: increment 4 < 6 -> short
    check sim.seats[2].allIn
    check sim.actingSeat == 0
    expect CosinoError:
      sim.act(akRaise, 20)  # betting is closed to seat 0
    sim.act(akCall)         # may only call the 4
    expect CosinoError:
      sim.act(akRaise, 20)  # and to seat 1
    sim.act(akCall)

  test "a full raise reopens the betting":
    var sim = fixtureConfig(3).freshHand(button = 0)
    sim.act(akRaise, 8)
    sim.act(akRaise, 20)    # sb three-bets: full raise
    sim.act(akFold)         # bb out
    sim.act(akRaise, 50)    # utg may four-bet
    check sim.currentBet == 50

suite "pots":
  test "all-in for less runs the board out":
    var config = fixtureConfig(2)
    var stacks = @[10, 100]
    var sim = initHand(config, 0, 0, stacks, @[0, 0], config.names,
      riggedDeck(@["As Ad", "7c 2d"], "Ks Qh 9d 5c 3h"))
    sim.act(akRaise, 10)    # sb shoves 10
    sim.act(akCall)
    check sim.done
    check sim.board.len == 5
    ## Aces double up: seat 0 had 10, wins 10 from seat 1.
    check sim.seats[0].stack == 20
    check sim.seats[1].stack == 90
    check sim.totalStacks() == 110

  test "the uncalled excess of a shove returns to the bettor":
    var config = fixtureConfig(2)
    var stacks = @[100, 40]
    var sim = initHand(config, 0, 0, stacks, @[0, 0], config.names,
      riggedDeck(@["As Ad", "7c 2d"], "Ks Qh 9d 5c 3h"))
    sim.act(akRaise, 100)   # sb shoves 100 into a 40 stack
    sim.act(akCall)         # bb calls all-in for 40
    check sim.done
    check sim.seats[0].stack == 140
    check sim.seats[1].stack == 0
    check sim.seats[1].isOut
    check sim.totalStacks() == 140

  test "side pots pay by commitment level":
    var config = fixtureConfig(3)
    var stacks = @[10, 50, 100]
    ## button 0 -> sb 1, bb 2, utg 0. Deal order from sb: seats 1, 2, 0.
    ## Rig: seat 0 (short) aces, seat 1 kings, seat 2 junk.
    var sim = initHand(config, 0, 0, stacks, @[0, 0, 0], config.names,
      riggedDeck(@["Ks Kd", "7c 2d", "As Ad"], "Qs Jh 9d 5c 3h"))
    sim.act(akRaise, 10)     # utg all-in 10
    sim.act(akRaise, 50)     # sb shoves 50
    sim.act(akCall)          # bb calls 50
    check sim.done
    ## Main pot 30 to the aces; side pot 80 to the kings; bb loses 50.
    check sim.seats[0].stack == 30
    check sim.seats[1].stack == 80
    check sim.seats[2].stack == 50
    check sim.totalStacks() == 160

  test "split pots share evenly with the odd chip clockwise of the button":
    var config = fixtureConfig(3, stack = 100)
    ## Identical hands for seats 1 and 2 (deal order sb=1, bb=2, utg=0):
    ## both play the board's straight.
    var sim = initHand(config, 0, 0, @[100, 100, 100], @[0, 0, 0],
      config.names,
      riggedDeck(@["2c 2d", "3c 3d", "Ks Kd"], "4s 5h 6d 7c 8h"))
    sim.act(akRaise, 11)   # utg (kings)
    sim.act(akCall)        # sb
    sim.act(akCall)        # bb
    for street in 0 ..< 3:
      for live in 0 ..< 3:
        sim.act(akCheck)
    check sim.done
    ## Board straight plays for everyone: 33 chips split three ways, 11 each.
    check sim.seats[0].stack == 100
    check sim.seats[1].stack == 100
    check sim.seats[2].stack == 100

  test "an odd chip goes to the first winner past the button":
    var config = fixtureConfig(2, sb = 1, bb = 3)
    var sim = initHand(config, 0, 0, @[100, 100], @[0, 0], config.names,
      riggedDeck(@["2c 2d", "2h 2s"], "4s 5h 6d 7c 8h"))
    sim.act(akCall)   # sb completes to 3
    sim.act(akCheck)
    for street in 0 ..< 3:
      sim.act(akCheck)
      sim.act(akCheck)
    check sim.done
    ## Pot of 6 splits 3/3 on the board straight.
    check sim.seats[0].stack == 100
    check sim.seats[1].stack == 100

suite "match":
  test "the button walks and stacks carry over":
    var config = fixtureConfig(3)
    var match = initMatch(config)
    check match.sim.button == 0
    ## Fold the first hand out.
    match.sim.act(akFold)
    match.sim.act(akFold)
    match.finishHand()
    check match.handsPlayed == 1
    check not match.done
    match.nextHand()
    check match.sim.button == 1
    check match.sim.hand == 1
    ## The big blind of hand 0 keeps its winnings.
    check match.sim.seats[2].stack + match.sim.seats[2].committed +
      match.sim.pot > 0

  test "the match ends at the hand limit":
    var config = fixtureConfig(2, hands = 2)
    var match = initMatch(config)
    match.sim.act(akFold)
    match.finishHand()
    match.nextHand()
    match.sim.act(akFold)
    match.finishHand()
    check match.done
    expect CosinoError:
      match.nextHand()

  test "a felted table ends the match early":
    var config = fixtureConfig(2, hands = 30)
    var match = initMatch(config)
    ## Both shove hand one; someone busts.
    match.sim.act(akRaise, 100)
    match.sim.act(akCall)
    check match.sim.done
    match.finishHand()
    check match.done
    var zero = 0
    for seat in match.sim.seats:
      if seat.stack == 0:
        inc zero
    check zero == 1

  test "busted seats sit out and the button skips them":
    var config = fixtureConfig(3)
    var stacks = @[100, 190, 10]
    var match = Match(config: config,
      sim: initHand(config, 0, 0, stacks, @[0, 0, 0], config.names,
        riggedDeck(@["Ks Kd", "7c 2d", "As Ad"], "Qs Jh 9d 5c 3h")))
    ## Seat 2 (bb, 7-2) calls a shove and busts.
    match.sim.act(akFold)        # utg 0
    match.sim.act(akRaise, 190)  # sb 1 shoves kings
    match.sim.act(akCall)        # bb 2 calls 10 with junk
    check match.sim.done
    check match.sim.seats[2].isOut
    match.finishHand()
    check not match.done
    match.nextHand()
    ## Button was 0; next funded seat clockwise is 1.
    check match.sim.button == 1
    check match.sim.seats[2].isOut
    ## Two funded seats play heads-up: sb is the button.
    check match.sim.sbSeat == 1
    check match.sim.bbSeat == 0

  test "results carry policy names and chip-share scores":
    var config = fixtureConfig(3)
    var match = initMatch(config)
    match.sim.act(akFold)
    match.sim.act(akFold)
    match.endMatchEarly()
    let results = match.resultsJson()
    check results["names"].mapIt(it.getStr()) == @["P1", "P2", "P3"]
    var total = 0.0
    for score in results["scores"]:
      total += score.getFloat()
    check abs(total - 1.0) < 1e-9
    var wins = 0
    for win in results["win"]:
      if win.getBool():
        inc wins
    check wins >= 1

suite "replay and serialization":
  test "events round-trip through json":
    let sim = fixtureConfig(3).freshHand()
    for event in sim.events:
      let back = eventFromJson(eventToJson(event))
      check back == event

  test "replay re-derivation matches the live hand":
    var config = fixtureConfig(3)
    var match = initMatch(config)
    ## Play a couple of full hands with mixed actions.
    match.sim.act(akRaise, 6)
    match.sim.act(akCall)
    match.sim.act(akCall)
    while not match.sim.done:
      match.sim.act(akCheck)
    match.finishHand()
    match.nextHand()
    match.sim.act(akFold)
    match.sim.act(akFold)
    match.finishHand()
    match.endMatchEarly()

    let frames = replayMatch(config, match.allEvents())
    check frames.len == match.allEvents().len + 1
    let last = frames[^1]
    for index, seat in match.sim.seats:
      check last.seats[index].stack == seat.stack
      check last.seats[index].holeCards == seat.holeCards
    check last.pot == 0
    check last.handDone

  test "the seed reproduces the deal":
    var config = fixtureConfig(4)
    config.seed = 1234
    let a = config.freshHand()
    let b = config.freshHand()
    check a.seats.mapIt(it.holeCards) == b.seats.mapIt(it.holeCards)
    var other = config
    other.seed = 4321
    check a.seats.mapIt(it.holeCards) !=
      other.freshHand().seats.mapIt(it.holeCards)

  test "sampleEpisode caps hands to the call budget":
    var config = defaultGameConfig()
    config.hands = 500
    for seats in 2 .. 6:
      config.players = @[]
      for index in 0 ..< seats:
        config.players.add(PlayerConfig(name: "P" & $index))
      config.sampled = false
      let drawn = sampleEpisode(config)
      check drawn.hands * (2 * seats + 2) <= EpisodeCallBudget
      check drawn.hands >= MinHands
      ## Idempotent.
      check sampleEpisode(drawn).hands == drawn.hands

suite "chip conservation fuzz":
  test "random legal games conserve chips and replay cleanly":
    var rng = initRand(99)
    for round in 0 ..< 60:
      let seats = 2 + rng.rand(4)
      var config = fixtureConfig(seats, stack = 20 + rng.rand(50),
        hands = 1 + rng.rand(6))
      config.seed = rng.rand(100_000)
      var match = initMatch(config)
      let chips = config.totalChips()
      while not match.done:
        while not match.sim.done:
          let seat = match.sim.actingSeat
          check seat >= 0
          ## Pick a random legal action.
          var choices: seq[PlayerAction]
          if match.sim.callAmount(seat) == 0:
            choices.add(PlayerAction(kind: akCheck))
          else:
            choices.add(PlayerAction(kind: akCall))
            choices.add(PlayerAction(kind: akFold))
          if match.sim.currentBet == 0:
            let ceiling = match.sim.maxRaiseTo(seat)
            if ceiling > 0:
              choices.add(PlayerAction(kind: akBet,
                amount: min(max(config.bigBlind, 1) + rng.rand(10), ceiling)))
          elif match.sim.canRaise(seat):
            let lo = match.sim.minRaiseTo(seat)
            let hi = match.sim.maxRaiseTo(seat)
            var to = lo + rng.rand(6)
            if to > hi: to = hi
            if to > match.sim.currentBet:
              choices.add(PlayerAction(kind: akRaise, amount: to))
          match.sim.applyAction(seat, choices[rng.rand(choices.high)])
        ## Every hand conserves the table's chips.
        var onTable = 0
        for s in match.sim.seats:
          onTable += s.stack
        check onTable == chips
        match.finishHand()
        if not match.done:
          match.nextHand()
      ## And the replay lands on the same stacks.
      let frames = replayMatch(config, match.allEvents())
      for index, seat in match.sim.seats:
        check frames[^1].seats[index].stack == seat.stack
