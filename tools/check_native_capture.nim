## Reconstruct a full ordinary native match without making any model requests.
## Usage: check_native_capture CONFIG TRAJECTORY REPLAY OPERATOR_PROMPT
import std/[json, os, sets, strutils]
import crunchy
import cosino/[llm, sim, prompts, training_capture]

let args = commandLineParams()
doAssert args.len in [4, 5]
let allowTruncated = args.len == 5 and args[4] == "--allow-truncated"
let configNode = parseFile(args[0])
var config = defaultGameConfig()
config.update($configNode)
config = sampleEpisode(config)
var game = initMatch(config)
config = game.config
let client = newScriptedClient(config) # Never loads credentials or creates a provider transport.
let selection = promptSelection(configNode)
let replay = parseFile(args[2])
var rows: seq[JsonNode]
var summary: JsonNode
for line in lines(args[1]):
  let row = parseJson(line)
  if row["event_type"].getStr() == "decision": rows.add(row)
  else: summary = row
var counts = newSeq[int](config.players.len)
var fallbacks = newSeq[int](config.players.len)
var forced = newSeq[int](config.players.len)
var promptsChecked = 0

proc observation(game: Match, seat: int): JsonNode =
  ## Independent projection of the documented native WS view, from the actual simulator.
  result = game.sim.tableStateJson()
  for index, player in result["seats"].getElems():
    if index != seat and not player["revealed"].getBool(): player["cards"] = newJArray()
  var events = newJArray()
  for event in game.allEvents():
    if event.kind == evDeal and event.seat != seat: continue
    if event.kind in [evCalib, evAudit]: continue
    var node = event.eventToJson()
    if event.kind == evHandStart:
      for field in ["pair", "mirror"]:
        if node.hasKey(field): node.delete(field)
    events.add(node)
  for field in ["pair", "mirror"]:
    if result.hasKey(field): result.delete(field)
  result["events"] = events
  result["type"] = %"state"
  result["game"] = %"cosino"
  result["hands"] = %config.hands
  result["handsPlayed"] = %game.handsPlayed
  result["variant"] = %($config.variant)
  result["chipRace"] = %config.chipRace
  result["startingStack"] = %config.startingStack
  result["ante"] = %config.ante
  result["smallBlind"] = %config.smallBlind
  result["bigBlind"] = %config.bigBlind
  result["started"] = %true
  result["done"] = %game.done
  result["connected"] = newJArray()
  for _ in config.players: result["connected"].add(%true)
  result["protocol"] = %"cosino.player.v2"
  result["slot"] = %seat
  result["rules"] = %(
    variantRules(config) & "\nCard IDs: rank = ID div 4 (0=deuce to 12=ace), " &
    "suit = ID mod 4 (clubs, diamonds, hearts, spades).\n" &
    (if config.chipRace:
      "Stacks carry between hands; a busted seat is out. Final chip share is the score."
     else: "Stacks reset each hand. Cumulative net chips determine the score."))
  result["actionSpace"] = game.sim.actionSpaceJson(seat)

for index, row in rows:
  doAssert not game.done
  let seat = game.sim.actingSeat
  doAssert row["seat"].getStr() == $seat
  doAssert row["decision_id"].getStr() == $(index + 1) & "-" & $seat
  var view = copy(row["observation"])
  let execution = view["native_execution"]
  doAssert view["pre_native_sha256"].getStr() ==
    sha256($game.sim.tableStateJson()).toHex.toLowerAscii()
  for field in ["scenario_family", "task_identity", "prompt_selection",
      "pre_native_sha256", "native_parsed_proposals", "native_requests", "native_execution", "capture_errors"]:
    if view.hasKey(field): view.delete(field)
  doAssert view == observation(game, seat), "private native view differs at " & row["decision_id"].getStr()
  var decision: Decision
  var parsed = false
  for attemptIndex, attempt in row["attempts"].getElems():
    let request = attempt["request"]
    let system = systemPrompt(game.sim, seat, selection)
    var user = userPrompt(game.sim, seat, args[3],
      "Hand " & $(game.sim.hand + 1) & " of " & $config.hands &
      " in the match (" & $config.variant & ").")
    if attemptIndex > 0:
      user.add("\nYour previous reply was invalid. Respond with ONLY the " &
        "requested JSON object and a legal action with a legal amount.")
    doAssert request["system"].getStr() == system
    doAssert request["messages"] == %*[{"role": "user", "content": user}]
    doAssert request["max_tokens"].getInt() == config.maxOutputTokens
    inc promptsChecked
    if attempt["response"].kind == JString:
      try:
        decision = parseDecision(game.sim, seat,
          extractJsonObject(attempt["response"].getStr()))
        parsed = true
      except CatchableError: discard
  if not parsed:
    let origin = execution["origin"].getStr()
    doAssert origin in ["model", "house", "rock"]
    decision = client.scriptedAction(game.sim, seat,
      if origin == "rock": blRock else: blHouse)
    # The original disabled-client early return does not increment native fallback counters.
    decision.fallback = row["attempts"].len > 0
  doAssert execution["parsed_action"] == %*{
    "action": $decision.action.kind, "amount": decision.action.amount, "say": decision.say}
  let before = game.sim.events.len
  let outcome = client.applyDecision(game.sim, seat, decision)
  var events = newJArray()
  for event in game.sim.events[before ..< game.sim.events.len]: events.add(event.eventToJson())
  doAssert events == execution["events"], "applied native events differ"
  doAssert execution["events_sha256"].getStr() == sha256($events).toHex.toLowerAscii()
  doAssert execution["post_native_sha256"].getStr() ==
    sha256($game.sim.tableStateJson()).toHex.toLowerAscii()
  inc counts[seat]
  fallbacks[seat] += outcome.fallbacks
  forced[seat] += outcome.forcedFolds
  if game.sim.done:
    game.finishHand()
    if not game.done:
      var nextHandRecorded = not allowTruncated or index != rows.high
      if not nextHandRecorded:
        for event in replay["events"]:
          if event["kind"].getStr() == "handStart" and event["hand"].getInt() == game.handsPlayed:
            nextHandRecorded = true
      if nextHandRecorded: game.nextHand()
if not game.done and allowTruncated:
  doAssert replay["results"]["reason"].getStr() == "deadline"
  if not game.sim.done: game.voidLiveHand()
  game.endMatchEarly(erDeadline)
doAssert game.done and (game.reason == erComplete or (allowTruncated and game.reason == erDeadline))
game.finishMatch()
var eventRows = newJArray()
for event in game.allEvents(): eventRows.add(event.eventToJson())
doAssert eventRows == replay["events"], "complete native replay differs"
let results = game.resultsJson(fallbacks, forced, counts)
var privateOutcome = copy(summary["outcome"])
if privateOutcome.hasKey("capture_errors"):
  doAssert summary["status"].getStr() == "failed"
  privateOutcome.delete("capture_errors")
doAssert results == privateOutcome and results == replay["results"]
let ids = identities(config)
doAssert summary["seed_family"].getStr() == ids.family
for row in rows:
  doAssert row["observation"]["scenario_family"].getStr() == ids.family
  doAssert row["observation"]["task_identity"].getStr() == ids.task
var shorter = config
shorter.hands = max(2, config.hands - 2)
doAssert identities(shorter).family == ids.family
if shorter.hands != config.hands: doAssert identities(shorter).task != ids.task
var changedRules = config
inc changedRules.startingStack
doAssert identities(changedRules).family == ids.family
doAssert identities(changedRules).task != ids.task
var alias = config
alias.model = "unused-local-identity-check"
inc alias.turnDelayMs
doAssert identities(alias) == ids
var other = config
inc other.seed
doAssert identities(other).family != ids.family
proc prefixes(config: GameConfig): seq[string] =
  let count = if config.duplicate: (config.hands + 1) div 2 else: config.hands
  let cards = config.players.len * config.variant.holeCount() + config.variant.boardSize()
  for pair in 0 ..< count:
    let deck = config.pairDeck(pair)
    result.add($(deck[0 ..< cards]))
let originalDeals = prefixes(config)
let otherDeals = prefixes(other)
var indexedOverlap = 0
var sharedDeals = initHashSet[string]()
for index in 0 ..< min(originalDeals.len, otherDeals.len):
  if originalDeals[index] == otherDeals[index]: inc indexedOverlap
for deal in originalDeals:
  if deal in otherDeals: sharedDeals.incl(deal)
echo pretty(%*{"complete_episode": game.reason == erComplete, "native_reason": $game.reason, "hands": game.handsPlayed, "decisions": rows.len,
  "prompt_requests": promptsChecked, "all_private_views_prompts_applied_events_replay_outcome_verified": true,
  "split_family": ids.family, "task_identity": ids.task,
  "horizon_and_same_deal_rule_grouping_verified": true,
  "model_and_delay_identity_exclusion_verified": true,
  "neighbor_seed_actual_prefix_audit": {"pair_or_hand_indices": originalDeals.len,
    "matching_index_prefixes": indexedOverlap, "shared_distinct_prefixes": sharedDeals.len,
    "qualification": "Distinct stream hash is not proof of disjoint deals or broader information sets."},
  "real_provider_calls": 0})
