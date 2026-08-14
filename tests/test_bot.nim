## The scripted baseline must play whole matches without ever proposing an
## illegal action — it is both the no-credentials fallback (offline
## certification) and a fieldable policy, so this is the completion path.

import std/[json, unittest]
import cosino/[llm, sim]

suite "scripted baseline":
  test "plays full matches legally at every table size":
    for seats in 2 .. 6:
      for seed in [1, 7, 42, 1234]:
        var config = defaultGameConfig()
        config.seed = seed
        config.hands = 12
        config.sampled = true
        for index in 0 ..< seats:
          config.players.add(PlayerConfig(name: "P" & $(index + 1)))
          config.tokens.add("t" & $index)
        let client = newLlmClient(config)
        var match = initMatch(config)
        let chips = config.totalChips()
        var actions = 0
        while not match.done:
          while not match.sim.done:
            let seat = match.sim.actingSeat
            let decision = client.scriptedAction(match.sim, seat)
            ## The bot's action must be legal as-is: applyAction raises on
            ## anything else and would fail this test.
            match.sim.applyAction(seat, decision.action)
            inc actions
            check actions < 10_000
          var onTable = 0
          for s in match.sim.seats:
            onTable += s.stack
          check onTable == chips
          match.finishHand()
          if not match.done:
            match.nextHand()
        check match.handsPlayed >= 1
        let results = match.resultsJson()
        var total = 0.0
        for score in results["scores"]:
          total += score.getFloat()
        check abs(total - 1.0) < 1e-9

  test "decide falls back to scripted with no credentials":
    var config = defaultGameConfig()
    config.hands = 2
    config.sampled = true
    for index in 0 ..< 3:
      config.players.add(PlayerConfig(name: "P" & $(index + 1)))
    let client = newLlmClient(config)
    var match = initMatch(config)
    let decision = client.decide(match.sim, match.sim.actingSeat,
      "raise every hand", scripted = false)
    match.sim.applyAction(match.sim.actingSeat, decision.action)
