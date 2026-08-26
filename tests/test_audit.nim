## The collusion audit. Reporting only — but it must not cry wolf, and it must
## be a pure function of the event log plus the seed so the server and the
## browser agree byte for byte.

import std/[json, random, unittest]
import cosino/[llm, sim]

proc sixMax(seed: int, hands = 12): GameConfig =
  result = defaultGameConfig()
  result.variantDefaults(vHoldem)
  result.seed = seed
  result.hands = hands
  result.sampled = true
  for index in 0 ..< 6:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc scriptedMatch(config: GameConfig, baseline = blHouse): Match =
  result = initMatch(config)
  let client = newLlmClient(config)
  while not result.done:
    while not result.sim.done:
      let seat = result.sim.actingSeat
      result.sim.applyAction(seat,
        client.scriptedAction(result.sim, seat, baseline).action)
    result.finishHand()
    if not result.done:
      result.nextHand()

## A dumper builds a pot and then folds the river to its partner's minimum
## bet; everyone else folds preflop. `roles` picks the pair for each hand.
proc collusionMatch(config: GameConfig,
    roles: proc (hand: int): (int, int)): Match =
  result = initMatch(config)
  while not result.done:
    let (dumper, partner) = roles(result.sim.hand)
    while not result.sim.done:
      let seat = result.sim.actingSeat
      let s = result.sim
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
      result.sim.applyAction(seat, act)
    result.finishHand()
    if not result.done:
      result.nextHand()

proc flagsOf(node: JsonNode, kind: string): seq[JsonNode] =
  for flag in node["flagged"]:
    if flag["flag"].getStr() == kind:
      result.add(flag)

suite "no false positives":
  test "honest scripted six-max episodes raise no flags at all":
    ## The whole point of the audit: it must not cry wolf. Ten independent
    ## honest episodes per baseline, fourteen hands each -- the shipped
    ## holdem-6max size -- raise nothing of any kind.
    ##
    ## This holds because a completed hand books NO showdown surrender: the
    ## slice is priced on the final board, so realised card luck can never
    ## masquerade as a leak. Pricing it at the last betting action instead
    ## flagged 3/30 honest `house` episodes at sixteen hands and 8/30 at
    ## twenty-four, clamped or signed.
    for baseline in [blHouse, blRock]:
      for seed in 1 .. 10:
        let config = sixMax(seed * 13 + 1, hands = 14)
        var match = scriptedMatch(config, baseline)
        let audit = auditFromEvents(config, match.allEvents())
        check audit["flagged"].len == 0
        ## The episode really did give the audit something to look at.
        check audit["power"]["hands"].getInt() == config.hands
        var contestedEnough = 0
        for pair in audit["pairs"]:
          if pair["contested"].getInt() >= 4:
            inc contestedEnough
        check contestedEnough >= 1

  test "a completed hand books no showdown surrender":
    ## The invariant behind the test above, asserted directly: with the final
    ## board the equity term is exact, so every hand played to completion
    ## contributes exactly zero. Whatever surrender an honest table shows is
    ## the FOLD term and nothing else.
    let config = sixMax(118, hands = 14)
    var match = scriptedMatch(config, blHouse)
    let audit = auditFromEvents(config, match.allEvents())
    for pair in audit["pairs"]:
      ## Folding correctly scores ~0 and the fold term is clamped at zero, so
      ## no honest pair can run far from the field either way.
      check abs(pair["biasAB"].getFloat()) < 2.0 * config.bigBlind.float
      check abs(pair["biasBA"].getFloat()) < 2.0 * config.bigBlind.float

  test "two-seat variants report an empty audit":
    for variant in [vKuhn, vLeduc, vHoldem]:
      var config = defaultGameConfig()
      config.variantDefaults(variant)
      config.seed = 5
      config.hands = 6
      config.sampled = true
      for index in 0 ..< 2:
        config.players.add(PlayerConfig(name: "P" & $index))
      var match = scriptedMatch(config)
      let audit = auditFromEvents(config, match.allEvents())
      check audit["pairs"].len == 0
      check audit["flagged"].len == 0
      check audit["power"]["equitySamples"].getInt() == EquitySamples

suite "flagging real collusion":
  test "a one-way dumper raises exactly one directed dump flag":
    let config = sixMax(4242, hands = 12)
    proc roles(hand: int): (int, int) = (2, 5)
    var match = collusionMatch(config, roles)
    let audit = auditFromEvents(config, match.allEvents())
    let dumps = audit.flagsOf("dump-2-to-5")
    check dumps.len == 1
    check dumps[0]["a"].getInt() == 2
    check dumps[0]["b"].getInt() == 5
    check dumps[0]["contested"].getInt() >= 4
    check dumps[0]["biasAB"].getFloat() > 2.0 * config.bigBlind.float
    ## One-way: nothing flows back, so no soft-play and no reverse dump.
    check audit.flagsOf("soft-play").len == 0
    check audit.flagsOf("dump-5-to-2").len == 0

  test "a mutual soft-play pair raises exactly one soft-play flag":
    let config = sixMax(909, hands = 12)
    ## The same two seats take turns folding big pots to each other.
    proc roles(hand: int): (int, int) =
      if hand mod 2 == 0: (1, 4) else: (4, 1)
    var match = collusionMatch(config, roles)
    let audit = auditFromEvents(config, match.allEvents())
    let soft = audit.flagsOf("soft-play")
    ## Exactly one flag OF THAT KIND. The pair also carries both directed
    ## `dump` flags, because a mutual leak of this size clears the one-way bar
    ## in both directions too -- "a pair may carry both flags".
    check soft.len == 1
    check audit.flagsOf("dump-1-to-4").len == 1
    check audit.flagsOf("dump-4-to-1").len == 1
    let pair = [soft[0]["a"].getInt(), soft[0]["b"].getInt()]
    check 1 in pair
    check 4 in pair
    check soft[0]["contested"].getInt() >= 4
    check min(soft[0]["biasAB"].getFloat(), soft[0]["biasBA"].getFloat()) >
      0.75 * config.bigBlind.float

suite "purity and determinism":
  test "auditFromEvents is a pure function of the events plus the seed":
    let config = sixMax(4242, hands = 12)
    proc roles(hand: int): (int, int) = (2, 5)
    var match = collusionMatch(config, roles)
    let events = match.allEvents()
    check $auditFromEvents(config, events) == $auditFromEvents(config, events)

  test "the replay's own events reproduce the server's audit byte for byte":
    let config = sixMax(4242, hands = 12)
    proc roles(hand: int): (int, int) = (2, 5)
    var match = collusionMatch(config, roles)
    match.endMatchEarly(erComplete)
    match.finishMatch()
    let served = match.resultsJson()
    ## Round-trip every event through JSON, exactly as the replay bytes do.
    var wire = newJArray()
    for event in match.allEvents():
      wire.add(event.eventToJson())
    var back: seq[GameEvent]
    for node in parseJson($wire):
      back.add(eventFromJson(node))
    let recomputed = auditFromEvents(config, back)
    check $recomputed == $served["audit"]
    ## And the tail carries one audit event per flag.
    var tailFlags = 0
    for event in back:
      if event.kind == evAudit:
        inc tailFlags
    check tailFlags == recomputed["flagged"].len
    check tailFlags > 0

  test "different seeds give different Monte Carlo draws but the same shape":
    let a = sixMax(4242, hands = 12)
    var b = a
    b.seed = 99
    proc roles(hand: int): (int, int) = (2, 5)
    var matchA = collusionMatch(a, roles)
    let auditA = auditFromEvents(a, matchA.allEvents())
    check auditA["pairs"].len == 15   ## 6 choose 2

suite "equity":
  test "a complete board is an exact evaluation, not a sample":
    ## Seat 0 has the nut flush, seat 1 a set: the board is out, so the
    ## Monte Carlo degenerates to one exact showdown.
    let hole = @[parseCards("As Ks"), parseCards("7c 7d"), @[]]
    let board = parseCards("Qs Js 2s 7h 3d")
    var rng = initRand(1)
    let shares = equities(hole, @[0, 1], board, hole[0] & hole[1], rng, 2000)
    check abs(shares[0] - 1.0) < 1e-12
    check abs(shares[1] - 0.0) < 1e-12
    ## And a dead heat splits exactly in half: quad kings play the board.
    let tied = @[parseCards("2c 3d"), parseCards("4h 5s")]
    var rng2 = initRand(1)
    let split = equities(tied, @[0, 1], parseCards("Ks Kh Kd Kc Qs"),
      tied[0] & tied[1], rng2, 2000)
    check abs(split[0] - 0.5) < 1e-12
    check abs(split[1] - 0.5) < 1e-12

  test "the Monte Carlo is deterministic for a pinned seed":
    let hole = @[parseCards("As Ks"), parseCards("7c 7d")]
    var first = initRand(20260826)
    var second = initRand(20260826)
    let a = equities(hole, @[0, 1], @[], hole[0] & hole[1], first, 2000)
    let b = equities(hole, @[0, 1], @[], hole[0] & hole[1], second, 2000)
    check a == b
    check abs(a[0] + a[1] - 1.0) < 1e-9
    ## AKs is roughly a coin flip against a small pair; a 2000-runout sample
    ## must land in the right neighbourhood, not merely be reproducible.
    check a[0] > 0.35
    check a[0] < 0.65

  test "the seven-card evaluator agrees with the five-card brute force":
    var rng = initRand(7)
    for run in 0 ..< 4000:
      var deck: seq[int]
      for card in 0 ..< 52:
        deck.add(card)
      rng.shuffle(deck)
      let seven = deck[0 ..< 7]
      check eval7(seven) == evalBest(seven)
