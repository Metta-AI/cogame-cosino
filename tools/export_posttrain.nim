## Stream complete private candidate matches; shared review owns training admission.
import std/[json, os, osproc, strutils]
import cosino/[llm, sim, prompts, evidence]

const OperatorPrompt = "Play to maximize your own score using only your cards and the public table."

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT MATCHES [FIRST_SEED] [VARIANT [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = absolutePath(args[0])
  let matches = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "kuhn"
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  doAssert matches >= 10 and firstSeed >= 1
  doAssert not dirExists(output) and not fileExists(output)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before generating a pinned candidate corpus"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  writePrivate(output / "trajectories.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  var runs = newJArray()
  try:
    for seed in firstSeed ..< firstSeed + matches:
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = newJArray()
      for seat in 0 ..< variantConfig["players"].len:
        runtimeConfig["tokens"].add(%("t" & $seat))
      runtimeConfig["seed"] = %seed
      config.update($runtimeConfig)
      config = sampleEpisode(config)
      let client = newScriptedClient(config)
      var match = initMatch(config)
      let family = "cosino-" & $seed
      let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
      var decisionId, fallbacks, forcedFolds: int
      while not match.done:
        let seat = match.sim.actingSeat
        let system = systemPrompt(match.sim, seat, selection)
        let user = userPrompt(match.sim, seat, OperatorPrompt,
          "Hand " & $(match.sim.hand + 1) & " of " & $config.hands &
          " in the match (" & $config.variant & ").")
        let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
        let view = %*{"observation": user, "legal_actions": match.sim.actionSpaceJson(seat),
          "prompt_template": selection.promptMetadata(system, user)}
        let teacher = client.scriptedAction(match.sim, seat, blHouse)
        var proposal = %*{"say": teacher.say, "action": $teacher.action.kind}
        if teacher.action.kind in [akBet, akRaise]: proposal["amount"] = %teacher.action.amount
        let parsed = parseDecision(match.sim, seat, proposal)
        let start = match.sim.events.len
        let outcome = client.applyDecision(match.sim, seat, parsed)
        fallbacks += outcome.fallbacks
        forcedFolds += outcome.forcedFolds
        var executed = %*{"say": parsed.say}
        for index in start ..< match.sim.events.len:
          let event = match.sim.events[index]
          if event.kind == evAction and event.seat == seat:
            executed["action"] = %($event.action)
            if event.action in [akBet, akRaise]: executed["amount"] = %event.amount
        doAssert executed.hasKey("action")
        let accepted = proposal == executed and outcome.fallbacks == 0 and outcome.forcedFolds == 0
        let attemptId = $decisionId & "-teacher"
        let attempt = %*{
          "attempt_id": attemptId, "policy": "scripted-house", "origin": "teacher",
          "inference_mode": "text_action", "prompt": messages,
          "response": $proposal, "parsed_action": proposal, "accepted": accepted,
          "request": newJNull(), "platform_call_id": newJNull(), "behavior_logprobs": newJNull(),
          "rejection_reason": (if accepted: newJNull() else: %"engine-normalized-submission")
        }
        if match.sim.done:
          match.finishHand()
          while not match.done:
            match.nextHand()
            if not match.sim.done: break
            match.finishHand()
        stream.writeLine($(%*{
          "schema_version": "1", "event_type": "decision", "episode_id": episode,
          "decision_id": $decisionId, "decision_index": decisionId,
          "game": "cosino", "game_version": "source-" & revision,
          "source_revision": revision, "seat": $seat, "visibility": "private",
          "observation": view, "prompt": (if accepted: messages else: newJNull()),
          "attempts": [attempt], "selected_attempt_id": (if accepted: %attemptId else: newJNull()),
          "executed_action": executed, "action_status": (if accepted: "accepted" else: "fallback"),
          "fallback_origin": (if accepted: newJNull() else: %"engine-normalized-submission"),
          "terminal": match.done
        }))
        inc decisionId
      doAssert decisionId > 0 and match.reason == erComplete
      var participants = newJObject()
      let n = config.players.len
      let divisor = if config.chipRace: 1 else: match.handsScored
      for seat in 0 ..< n:
        let share = 1.0 / float(n) + float(match.net[seat]) / float(n * config.startingStack * divisor)
        participants[$seat] = %*{"score": share}
      stream.writeLine($(%*{
        "schema_version": "1", "event_type": "episode", "episode_id": episode,
        "seed_family": family, "game": "cosino", "game_version": "source-" & revision,
        "source_revision": revision, "status": "completed",
        "outcome": {"net": match.net, "hands": match.handsPlayed,
          "hands_scored": match.handsScored, "reason": "complete",
          "fallbacks": fallbacks, "forced_folds": forcedFolds},
        "participant_outcomes": participants
      }))
      runs.add(%*{"seed": seed, "decisions": decisionId, "hands": match.handsPlayed, "net": match.net})
  finally:
    stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "cosino", "variant": variant,
    "source_revision": revision, "teacher": "scripted-house",
    "prompt_selection": selection.selectionMetadata(),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "runs": runs}) & "\n")
  echo "complete games=", matches
