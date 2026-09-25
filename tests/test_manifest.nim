## The manifest is a contract with the platform validator, and the platform is
## the only thing that reads it end to end. Every rule below cost somebody a
## red release once.

import std/[json, os, strutils, unittest]
import cosino/[llm, sim]

const
  RepoRoot = currentSourcePath().parentDir().parentDir()
  ManifestPath = RepoRoot / "coworld_manifest_template.json"
  PoliciesPath = RepoRoot / "tools" / "ci" / "policies.json"
  ComposePath = RepoRoot / "compose.yaml"

let manifest = parseJson(readFile(ManifestPath))
let game = manifest["game"]

suite "top-level shape":
  test "the upload contract's required and forbidden keys":
    check manifest.hasKey("$schema")
    check manifest["tags"].len >= 3
    ## The validator requires game.description and FORBIDS game.tags; tags
    ## live top-level only (pistonball 0.1.0).
    check game.hasKey("description")
    check game["description"].getStr().len > 200
    check not game.hasKey("tags")
    ## coworld 0.1.42's _load_template_manifest: no top-level version, no
    ## game.display_name, game.owner required.
    check not manifest.hasKey("version")
    check not game.hasKey("display_name")
    check game["owner"].getStr().len > 0
    check manifest["episode_timeout_minutes"].getInt() == 20

  test "the replay viewer is a STATIC bundle nested under game":
    check not manifest.hasKey("replay_viewer")
    check game["replay_viewer"]["bundle"].getStr() == "static-replay-viewer"

  test "the image placeholder is derived from the compose service name":
    let compose = readFile(ComposePath)
    check "  cosino:" in compose
    check "image: coworld-cosino:latest" in compose
    check game["runnable"]["image"].getStr() == "{{COSINO_IMAGE}}"
    for entry in manifest["player"]:
      check entry["image"].getStr() == "{{COSINO_IMAGE}}"

  test "the game runnable carries the secret URI in game.name's namespace":
    let runnable = game["runnable"]
    check runnable["type"].getStr() == "game"
    check runnable["run"].getElems() == @[%"/bin/cosino"]
    ## The LLM runs GAME-side, so the GAME runnable needs the key (hive,
    ## 2026-08-23), and the namespace is game.name, not the repo slug.
    check runnable["env"]["ANTHROPIC_API_KEY_URI"].getStr() ==
      "secret://coworld/" & game["name"].getStr() & "/anthropic_api_key"
    check game["name"].getStr() == "cosino"

suite "protocols and docs":
  test "protocols carry BOTH player and global as {type,value} objects":
    for key in ["player", "global"]:
      let node = game["protocols"][key]
      check node.kind == JObject
      check node["type"].getStr() == "text"
      check node["value"].getStr().len > 200
    check "cosino.player.v2" in game["protocols"]["player"]["value"].getStr()
    check "PLAYER_PROMPT" in game["protocols"]["player"]["value"].getStr()
    check "PLAYER_SCRIPTED" in game["protocols"]["player"]["value"].getStr()

  test "docs are a readme object plus the three named pages":
    let docs = game["docs"]
    check docs["readme"].kind == JObject
    check docs["readme"]["type"].getStr() == "text"
    check docs["readme"]["value"].getStr().len > 200
    var ids: seq[string]
    for page in docs["pages"]:
      check page["content"]["type"].getStr() == "text"
      check page["content"]["value"].getStr().len > 200
      check page["title"].getStr().len > 0
      ids.add(page["id"].getStr())
    check ids == @["rules.md", "ladder.md", "audit.md"]

suite "schemas":
  test "every config_schema ARRAY property declares minItems and maxItems":
    ## Not just `required` membership: the validator wants bounds (tandem
    ## 0.1.0, 2026-08-23).
    var arrays = 0
    for name, prop in game["config_schema"]["properties"].pairs:
      if prop{"type"}.getStr() == "array":
        inc arrays
        check prop.hasKey("minItems")
        check prop.hasKey("maxItems")
        check prop["minItems"].getInt() == 2
        check prop["maxItems"].getInt() == 6
    check arrays == 2      ## tokens and players, both bounded to num_agents

  test "results_schema declares the reason enum and every reported field":
    let props = game["results_schema"]["properties"]
    var reasons: seq[string]
    for value in props["reason"]["enum"]:
      reasons.add(value.getStr())
    check reasons == @["complete", "deadline", "budget"]
    for reason in EndReason:
      check $reason in reasons
    for key in ["names", "scores", "win", "net", "netPerHand", "unitsPerHand",
        "handsWon", "stackOffs", "stacks", "busted", "fallbacks",
        "forcedFolds", "decisions", "exploitability",
        "exploitabilityCoverage", "exploitabilityFill", "audit", "variant",
        "chipRace", "seats", "handsPlayed", "handsScored", "hands",
        "pairsComplete", "unpairedHands", "startingStack", "ante",
        "smallBlind", "bigBlind", "seed", "seatOrder", "reason"]:
      check props.hasKey(key)
    for name, prop in props.pairs:
      if prop{"type"}.getStr() == "array":
        check prop.hasKey("minItems")
        check prop.hasKey("maxItems")

  test "the results the game actually writes satisfy the schema's key set":
    var config = defaultGameConfig()
    config.variantDefaults(vKuhn)
    config.seed = 7
    config.hands = 4
    config.sampled = true
    for index in 0 ..< 2:
      config.players.add(PlayerConfig(name: "P" & $index))
      config.tokens.add("t" & $index)
    var match = initMatch(config)
    let client = newLlmClient(config)
    while not match.done:
      while not match.sim.done:
        let seat = match.sim.actingSeat
        match.sim.applyAction(seat,
          client.scriptedAction(match.sim, seat).action)
      match.finishHand()
      if not match.done:
        match.nextHand()
    match.finishMatch()
    let results = match.resultsJson(@[0, 0], @[0, 0], @[1, 1])
    let props = game["results_schema"]["properties"]
    for key, _ in results.pairs:
      check props.hasKey(key)
    for key in game["results_schema"]["required"]:
      check results.hasKey(key.getStr())

suite "seats: num_agents everywhere":
  test "every variant declares num_agents and matches its players length":
    check manifest["variants"].len == 6
    var ids: seq[string]
    for variant in manifest["variants"]:
      ids.add(variant["id"].getStr())
      ## variants[].description is required by the upload contract.
      check variant["description"].getStr().len > 40
      check variant["name"].getStr().len > 0
      let config = variant["game_config"]
      check config.hasKey("num_agents")
      let seats = config["num_agents"].getInt()
      check seats >= 2
      check seats <= MaxSeats
      check config["players"].len == seats
      ## No runner-managed tokens in a declared config.
      check not config.hasKey("tokens")
    check ids == @["kuhn", "leduc", "holdem-hu", "holdem-6max",
      "headsup", "sixmax"]

  test "the certification fixture agrees with itself four ways":
    let cert = manifest["certification"]
    let config = cert["game_config"]
    check config["num_agents"].getInt() == 2
    check cert["players"].len == 2
    check config["players"].len == 2
    ## SMOKE_SEATS / <SEATS> in ci.yml is the fourth declaration.
    let ci = readFile(RepoRoot / ".github" / "workflows" / "ci.yml")
    check "SMOKE_SLUG: ${{ env.SLUG }}" in ci
    let smoke = readFile(RepoRoot / "tools" / "ci" / "docker_smoke.sh")
    check "seats_expected=\"${SMOKE_SEATS:-2}\"" in smoke
    ## The fixture is the design's: 12 Kuhn hands, seed 7, no pacing.
    check config["variant"].getStr() == "kuhn"
    check config["seed"].getInt() == 7
    check config["hands"].getInt() == 12
    check config["turnDelayMs"].getInt() == 0
    check config["duplicate"].getBool()
    check not config.hasKey("tokens")

  test "every declared player runnable occupies a certification slot":
    ## A declared player with no slot fails `players_missing` (raid 0.1.3).
    var declared: seq[string]
    for entry in manifest["player"]:
      declared.add(entry["id"].getStr())
      check entry["type"].getStr() == "player"
      check entry["description"].getStr().len > 40
      check entry["run"].getElems() == @[%"/bin/cosino-player"]
      ## 500m is below the platform minimum (pistonball 0.1.1).
      check entry["resources"]["limits"]["cpu"].getStr() == "1"
      check entry["resources"]["requests"]["cpu"].getStr() == "100m"
    check declared == @["cosino-player", "cosino-baseline"]
    var seated: seq[string]
    for slot in manifest["certification"]["players"]:
      seated.add(slot["player_id"].getStr())
    for id in declared:
      check id in seated
    for id in seated:
      check id in declared

suite "every declared game_config actually constructs":
  test "each variant and the cert fixture build a live match":
    var configs: seq[JsonNode]
    for variant in manifest["variants"]:
      configs.add(variant["game_config"])
    configs.add(manifest["certification"]["game_config"])
    for node in configs:
      var body = copy(node)
      let seats = body["num_agents"].getInt()
      var tokens = newJArray()
      for slot in 0 ..< seats:
        tokens.add(%("token-" & $slot))
      body["tokens"] = tokens
      body.delete("num_agents")
      var config = defaultGameConfig()
      config.update($body)
      config = sampleEpisode(config)
      check config.players.len == seats
      check config.hands >= MinHands
      check config.hands mod 2 == 0
      ## The declared hand count survives the budget fit untouched.
      check config.hands == node["hands"].getInt()
      var match = initMatch(config)
      check match.sim.actingSeat >= 0
      check match.config.seatOrder.len == seats

suite "policies":
  test "two prompt champions and two scripted fillers, champion #2 owned":
    let policies = parseJson(readFile(PoliciesPath))
    check policies.len == 4
    var names: seq[string]
    var prompts = 0
    var scripted = 0
    var owned = 0
    for entry in policies:
      names.add(entry["name"].getStr())
      check entry["run"].getStr() == "/bin/cosino-player"
      let env = entry["env"]
      if env.hasKey("PLAYER_PROMPT"):
        inc prompts
        check env["PLAYER_PROMPT"].getStr().len > 200
        ## No USE_BEDROCK: this lineage runs the LLM GAME-side (cogolf).
        check not env.hasKey("USE_BEDROCK")
      if env.hasKey("PLAYER_SCRIPTED"):
        inc scripted
        check parseBaseline(env["PLAYER_SCRIPTED"].getStr()) in
          [blHouse, blRock]
      if entry.hasKey("player"):
        inc owned
        check entry["player"].getStr().startsWith("ply_")
    check names == @["cosino-scholar", "cosino-exploiter", "cosino-house",
      "cosino-rock"]
    check prompts == 2
    check scripted == 2
    ## Champion #2 is uploaded while daveey-1 is the active player.
    check owned == 1
    check policies[1]["player"].getStr() ==
      "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    ## Filler versions must differ from champion versions: distinct content.
    var bodies: seq[string]
    for entry in policies:
      bodies.add($entry["env"])
    for i in 0 ..< bodies.len:
      for j in i + 1 ..< bodies.len:
        check bodies[i] != bodies[j]
