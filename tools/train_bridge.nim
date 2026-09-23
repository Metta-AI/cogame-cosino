## Persistent numeric decision bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:cosino-train-bridge tools/train_bridge.nim

import std/[json, os]
import cosino/[llm, sim]

const
  OperatorPrompt = "Play to maximize your own score using only your cards and the public table."
  Variants = ["kuhn", "leduc", "holdem-hu", "holdem-6max", "headsup", "sixmax"]
  ActionCount = 7

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc action(kind: ActionKind, amount = 0): JsonNode =
  result = %*{"say": "", "action": $kind}
  if kind in [akBet, akRaise]:
    result["amount"] = %amount

proc choices(sim: Sim, seat: int): JsonNode =
  ## Fixed slots and null masks keep the policy shape stable across streets.
  result = newJArray()
  result.add(action(akFold))
  result.add(if sim.callAmount(seat) == 0: action(akCheck) else: newJNull())
  result.add(if sim.callAmount(seat) > 0: action(akCall) else: newJNull())
  let wagerKind = if sim.currentBet == 0: akBet else: akRaise
  let canWager = if wagerKind == akBet: sim.canBet(seat) else: sim.canRaise(seat)
  if not canWager:
    for slot in 3 ..< ActionCount:
      result.add(newJNull())
    return
  let low = if wagerKind == akBet: sim.minBet(seat) else: sim.minRaiseTo(seat)
  let high = sim.maxRaiseTo(seat)
  let targets = [low, max(low, min(high, sim.currentBet + sim.pot div 2)),
    max(low, min(high, sim.currentBet + sim.pot)), high]
  for target in targets:
    let candidate = action(wagerKind, target)
    var duplicate = false
    for existing in result:
      if existing == candidate:
        duplicate = true
    result.add(if duplicate: newJNull() else: candidate)

proc decision(match: Match, seat, id: int): JsonNode =
  let sim = match.sim
  var publicSeats = newJArray()
  for slot, player in sim.seats:
    publicSeats.add(%*{"seat": slot, "stack": player.stack,
      "committed": player.committed, "net": player.net,
      "hands_won": player.handsWon, "folded": player.folded,
      "all_in": player.allIn, "out": player.isOut,
      "revealed": player.revealed,
      "revealed_cards": (if player.revealed: %player.holeCards else: newJArray())})
  var legal = newJArray()
  for candidate in sim.choices(seat):
    if candidate.kind != JNull:
      legal.add(candidate)
  %*{
    "kind": "decision", "game": "cosino", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": match.handsPlayed,
    "semantic_view": {"hand": sim.hand, "hands": match.config.hands,
      "street": $sim.street, "seats": publicSeats,
      "board": sim.board, "hole_cards": sim.seats[seat].holeCards,
      "pot": sim.pot, "current_bet": sim.currentBet,
      "call_amount": sim.callAmount(seat), "legal_actions": legal},
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(sim, seat)},
      {"role": "user", "content": userPrompt(sim, seat, OperatorPrompt,
        "Hand " & $(sim.hand + 1) & " of " & $match.config.hands &
        " in the match (" & $match.config.variant & ").")}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "enum": legal},
    "typed_question": newJNull()
  }

proc encoding(match: Match, seat, id: int, variant: string): JsonNode =
  let sim = match.sim
  var values = newJArray()
  for name in Variants:
    values.add(%(if variant == name: 1 else: 0))
  for slot in 0 ..< MaxSeats:
    values.add(%(if seat == slot: 1 else: 0))
  for value in [sim.hand, match.config.hands, sim.round, sim.wagers,
      sim.currentBet, sim.minRaiseSize, sim.pot, sim.button,
      sim.sbSeat, sim.bbSeat, sim.callAmount(seat),
      sim.minBet(seat), sim.minRaiseTo(seat), sim.maxRaiseTo(seat)]:
    values.add(%value)
  for street in Street:
    values.add(%(if sim.street == street: 1 else: 0))
  for slot in 0 ..< MaxSeats:
    if slot < sim.seats.len:
      let player = sim.seats[slot]
      for value in [player.stack, player.committed, player.totalCommitted,
          player.net, player.handsWon, sim.posOf[slot]]:
        values.add(%value)
      for flag in [player.folded, player.allIn, player.acted,
          player.mayRaise, player.isOut]:
        values.add(%(if flag: 1 else: 0))
    else:
      for field in 0 ..< 11:
        values.add(%0)
  for card in 0 ..< 2:
    values.add(%(if card < sim.seats[seat].holeCards.len:
      sim.seats[seat].holeCards[card] + 1 else: 0))
  for card in 0 ..< 5:
    values.add(%(if card < sim.board.len: sim.board[card] + 1 else: 0))
  var publicEvents: seq[GameEvent]
  for event in sim.events:
    if event.kind in [evAction, evBoard]:
      publicEvents.add(event)
  for offset in 0 ..< 16:
    if offset < publicEvents.len:
      let event = publicEvents[publicEvents.len - 1 - offset]
      for value in [event.seat + 1, ord(event.kind),
          (if event.kind == evAction: ord(event.action) else: 0),
          event.amount, ord(event.street), event.potAfter]:
        values.add(%value)
    else:
      for field in 0 ..< 6:
        values.add(%0)
  %*{"decision_id": id, "values": values, "actions": sim.choices(seat)}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: cosino-train-bridge MANIFEST [variant]", 1)
  let variant = if args.len == 2: args[1] else: "kuhn"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var match: Match
  var client: LlmClient
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == variantConfig["players"].len
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      runtimeConfig["tokens"] = newJArray()
      for seat in 0 ..< variantConfig["players"].len:
        runtimeConfig["tokens"].add(%("t" & $seat))
      config.update($runtimeConfig)
      config = sampleEpisode(config)
      match = initMatch(config)
      client = newScriptedClient(config)
      id = 0
      response = match.decision(match.sim.actingSeat, id)
    of "encode":
      doAssert not match.done
      response = match.encoding(match.sim.actingSeat, id, variant)
    of "teacher":
      doAssert not match.done
      let seat = match.sim.actingSeat
      let scripted = client.scriptedAction(match.sim, seat, blHouse).action
      let available = match.sim.choices(seat)
      var selected = available[0]
      var distance = high(int)
      for candidate in available:
        if candidate.kind == JNull or candidate["action"].getStr() != $scripted.kind:
          continue
        let delta = if scripted.kind in [akBet, akRaise]:
          abs(candidate["amount"].getInt() - scripted.amount) else: 0
        if delta < distance:
          selected = candidate
          distance = delta
      doAssert distance < high(int), "scripted action has no legal candidate"
      response = %*{"response": $selected}
    of "step":
      doAssert not match.done and request["decision_id"].getInt() == id
      let seat = match.sim.actingSeat
      let chosen = parseJson(request["response"].getStr())
      doAssert chosen in match.sim.choices(seat)
      let parsed = parseDecision(match.sim, seat, chosen)
      match.sim.recordSay(seat, parsed.say)
      match.sim.applyAction(seat, parsed.action)
      if match.sim.done:
        match.finishHand()
        while not match.done:
          match.nextHand()
          if not match.sim.done:
            break
          match.finishHand()
      inc id
      var observation: JsonNode
      if match.done:
        var scores = newJObject()
        let n = match.config.players.len
        for slot in 0 ..< n:
          let divisor = if match.config.chipRace: 1 else: match.handsScored
          let share = 1.0 / float(n) + float(match.net[slot]) /
            float(n * match.config.startingStack * divisor)
          scores[$slot] = %share
        observation = %*{"kind": "terminal", "scores": scores}
      else:
        observation = match.decision(match.sim.actingSeat, id)
      response = %*{"kind": "accepted", "action": chosen,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
