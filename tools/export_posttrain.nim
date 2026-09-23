## Export complete Cosino matches as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT MATCHES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import cosino/[llm, sim]

const OperatorPrompt = "Play to maximize your own score using only your cards and the public table."
const Variants = ["kuhn", "leduc", "holdem-hu", "holdem-6max", "headsup", "sixmax"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT MATCHES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let matches = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "kuhn"
  if matches < 10 or firstSeed < 1:
    quit("at least ten matches and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + matches:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< variantConfig["players"].len:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    config = sampleEpisode(config)
    let client = newLlmClient(config)
    var match = initMatch(config)
    var rows: seq[string]
    var decisions = 0
    while not match.done:
      while not match.sim.done:
        let seat = match.sim.actingSeat
        let decision = client.scriptedAction(match.sim, seat, blHouse)
        var completion = %*{"say": decision.say, "action": $decision.action.kind}
        if decision.action.kind in [akBet, akRaise]:
          completion["amount"] = %decision.action.amount
        let parsed = parseDecision(match.sim, seat, completion)
        doAssert parsed.action == decision.action
        rows.add($(%*{
          "episode_id": "cosino-" & variant & "-" & $seed,
          "seed": "cosino-" & variant & "-" & $seed,
          "decision_id": decisions,
          "prompt": [
            {"role": "system", "content": systemPrompt(match.sim, seat)},
            {"role": "user", "content": userPrompt(match.sim, seat,
              OperatorPrompt, "Hand " & $(match.sim.hand + 1) & " of " &
              $config.hands & " in the match (" & $config.variant & ").")}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "cosino",
          "action_schema_revision": "cosino-action-v1"
        }))
        match.sim.recordSay(seat, parsed.say)
        match.sim.applyAction(seat, parsed.action)
        inc decisions
      match.finishHand()
      if not match.done:
        match.nextHand()
    doAssert rows.len > 0 and match.reason == erComplete
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "hands": match.handsPlayed, "net": match.net})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "cosino",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-house",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
