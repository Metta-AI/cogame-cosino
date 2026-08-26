## The scripted baselines are the completion path: they are the
## no-credentials fallback (offline certification), the fallback whenever a
## model decision fails, AND two fieldable policies. They must be legal at
## every rung and every seat count, always.

import std/[json, monotimes, strutils, times, unicode, unittest]
import cosino/[llm, sim]

proc fixture(variant: Variant, seats: int, seed: int,
    hands = 8): GameConfig =
  result = defaultGameConfig()
  result.variantDefaults(variant)
  result.seed = seed
  result.hands = hands
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

suite "bounded orders: the baseline is always legal":
  test "house and rock play 200 matches at every rung and seat count":
    ## 4 tables x 2 baselines x 200 matches. `applyAction` raises on ANY
    ## illegal move, so a single bad amount or an out-of-turn action fails
    ## this test.
    for (variant, seats) in [(vKuhn, 2), (vLeduc, 2), (vHoldem, 2),
        (vHoldem, 6)]:
      for baseline in [blHouse, blRock]:
        for run in 0 ..< 200:
          var config = fixture(variant, seats, 1000 + run)
          let client = newLlmClient(config)
          var match = initMatch(config)
          let chips = seats * config.startingStack
          var actions = 0
          while not match.done:
            while not match.sim.done:
              let seat = match.sim.actingSeat
              check seat >= 0
              let decision = client.scriptedAction(match.sim, seat, baseline)
              ## Every amount must already be inside the engine's own bounds.
              case decision.action.kind
              of akBet:
                check decision.action.amount >= match.sim.minBet(seat)
                check decision.action.amount <= match.sim.maxRaiseTo(seat)
              of akRaise:
                check decision.action.amount >= match.sim.minRaiseTo(seat)
                check decision.action.amount <= match.sim.maxRaiseTo(seat)
              else: discard
              match.sim.applyAction(seat, decision.action)
              inc actions
              check actions < 20_000
            var onTable = 0
            for seat in match.sim.seats:
              onTable += seat.stack
            check onTable == chips
            match.finishHand()
            if not match.done:
              match.nextHand()
          check match.handsPlayed == config.hands
          ## Zero-sum, and the score share therefore sums to exactly 1.
          ## (The recorded tail -- calib and audit -- is exercised by
          ## test_sim and test_audit; running the exact solver and the
          ## 2000-runout equity Monte Carlo 1600 times over would say
          ## nothing new and would cost minutes.)
          var netSum = 0
          var total = 0.0
          for slot in 0 ..< seats:
            netSum += match.net[slot]
            total += 1.0 / seats.float + match.net[slot].float /
              (seats.float * config.startingStack.float *
                match.handsScored.float)
          check netSum == 0
          check abs(total - 1.0) < 1e-9

suite "degrade, never hang":
  test "decide with no credentials returns the scripted move immediately":
    var config = fixture(vHoldem, 3, 11)
    let client = newLlmClient(config)
    check not client.credentialled()
    var match = initMatch(config)
    let seat = match.sim.actingSeat
    let started = getMonoTime()
    let decision = client.decide(match.sim, seat, "raise every hand",
      scripted = false)
    let elapsed = (getMonoTime() - started).inMilliseconds
    ## No network wait at all: no retries, no spacing floor, no timeout.
    check elapsed < 500
    check not decision.fallback
    match.sim.applyAction(seat, decision.action)

  test "an unparseable reply cannot reach the engine":
    for garbage in ["", "I think I will raise", "```\nnope\n```"]:
      expect CosinoError:
        discard extractJsonObject(garbage)

  test "an illegal action falls back to the baseline and increments fallbacks":
    var config = fixture(vHoldem, 3, 12)
    let client = newLlmClient(config)
    var match = initMatch(config)
    let seat = match.sim.actingSeat
    ## A raise far beyond the stack: the engine rejects it outright.
    let bogus = Decision(say: "shove",
      action: PlayerAction(kind: akRaise, amount: 10_000))
    let outcome = client.applyDecision(match.sim, seat, bogus)
    check outcome.fallbacks == 1
    check outcome.forcedFolds == 0
    check match.sim.actingSeat != seat or match.sim.done

  test "a model fallback is counted even when its action is legal":
    var config = fixture(vHoldem, 3, 13)
    let client = newLlmClient(config)
    var match = initMatch(config)
    let seat = match.sim.actingSeat
    var decision = client.scriptedAction(match.sim, seat)
    decision.fallback = true
    decision.error = "llm throttled (429)"
    let outcome = client.applyDecision(match.sim, seat, decision)
    check outcome.fallbacks == 1
    check outcome.forcedFolds == 0

  test "a baseline the engine rejects yields a fold and a forcedFold":
    var config = fixture(vHoldem, 3, 14)
    let client = newLlmClient(config)
    var match = initMatch(config)
    let seat = match.sim.actingSeat
    let bogus = Decision(action: PlayerAction(kind: akRaise, amount: 10_000))
    ## A deliberately broken baseline: checking is illegal facing the blind.
    proc brokenBaseline(sim: Sim, seat: int): PlayerAction =
      PlayerAction(kind: akCheck)
    let outcome = client.applyDecision(match.sim, seat, bogus,
      baselineFor = brokenBaseline)
    check outcome.fallbacks == 1
    check outcome.forcedFolds == 1
    check match.sim.seats[seat].folded

suite "hostile model output":
  test "a 5 kB emoji say is capped at 120 runes and the replay stays UTF-8":
    var config = fixture(vHoldem, 3, 15)
    var match = initMatch(config)
    let seat = match.sim.actingSeat
    let hostile = "\u{1F0A1}\u{1F0D2}\u{1F0B3}".repeat(700)
    check hostile.len > 5000
    let payload = %*{"say": hostile, "action": "fold"}
    let decision = parseDecision(match.sim, seat, payload)
    check decision.say.runeLen == MaxSayLen
    check decision.say.validateUtf8() == -1
    match.sim.recordSay(seat, decision.say)
    match.sim.applyAction(seat, decision.action)
    var events = newJArray()
    for event in match.allEvents():
      events.add(event.eventToJson())
    let replay = $ %*{"events": events}
    check replay.validateUtf8() == -1
    ## And it survives a strict round trip through the JSON parser.
    let reparsed = parseJson(replay)
    var found = false
    for node in reparsed["events"]:
      if node{"kind"}.getStr() == "say":
        found = true
        check node["text"].getStr().runeLen == MaxSayLen
    check found

  test "unknown verbs are rejected, allin normalises":
    var config = fixture(vHoldem, 3, 16)
    var match = initMatch(config)
    let seat = match.sim.actingSeat
    expect CosinoError:
      discard parseDecision(match.sim, seat, %*{"action": "teleport"})
    let shove = parseDecision(match.sim, seat, %*{"action": "shove"})
    check shove.action.kind in [akBet, akRaise, akCall]
    match.sim.applyAction(seat, shove.action)

  test "baselines are selected by name, anything else is house":
    check parseBaseline("rock") == blRock
    check parseBaseline("ROCK") == blRock
    check parseBaseline("house") == blHouse
    check parseBaseline("") == blHouse
    check parseBaseline("whatever") == blHouse
