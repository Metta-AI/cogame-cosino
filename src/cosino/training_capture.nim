## Optional private evidence from the ordinary native game, never a player or learner.
import std/[base64, json, math, options, os, parsejson,
  streams, strutils, tables, uri]
import crunchy, curly, bitworld/runtime
import ./decision_trajectory, ./sim
export decision_trajectory, options

const
  MaxRequestEvidenceBytes* = 65_536
  MaxResponseEvidenceBytes* = 65_536
  MaxResponseHeaderEvidenceBytes* = 16_384
  MaxObservationEvidenceBytes* = 131_072
  MaxEpisodeEvidenceBytes* = 24 * 1024 * 1024

type
  CapturedDecision* = ref object
    id, policy: string
    observation: JsonNode
    attempts: seq[DecisionAttempt]
    generated: seq[string]
    failed: bool
  RuntimeCapture* = ref object
    trajectory: DecisionTrajectory
    family*, task*: string
    failed: bool
    evidenceBytes: int
    errors: seq[string]

proc scalarUtf8(text: string): bool =
  ## RFC 3629: Nim's validateUtf8 alone permits encoded surrogate code points.
  var index = 0
  while index < text.len:
    let first = ord(text[index])
    var size = 1
    if first <= 0x7f: discard
    elif first in 0xc2 .. 0xdf: size = 2
    elif first in 0xe0 .. 0xef: size = 3
    elif first in 0xf0 .. 0xf4: size = 4
    else: return false
    if index + size > text.len: return false
    for offset in 1 ..< size:
      if ord(text[index + offset]) notin 0x80 .. 0xbf: return false
    if size >= 3:
      let second = ord(text[index + 1])
      if first == 0xe0 and second < 0xa0 or first == 0xed and second > 0x9f or
          first == 0xf0 and second < 0x90 or first == 0xf4 and second > 0x8f:
        return false
    index += size
  true

proc scalarJson(node: JsonNode, depth = 0): bool =
  if node == nil or depth > 64: return false
  case node.kind
  of JString: return scalarUtf8(node.getStr())
  of JObject:
    for key, value in node:
      if not scalarUtf8(key) or not scalarJson(value, depth + 1): return false
  of JArray:
    for value in node:
      if not scalarJson(value, depth + 1): return false
  else: discard
  true

proc safeDiagnostic(detail: string): string =
  if scalarUtf8(detail): detail
  else: "non-Unicode diagnostic bytes, base64=" & encode(detail)

proc captureError(capture: CapturedDecision, detail: string) =
  capture.failed = true
  if capture.observation != nil:
    if not capture.observation.hasKey("capture_errors"):
      capture.observation["capture_errors"] = newJArray()
    capture.observation["capture_errors"].add(%safeDiagnostic(detail))
  echo "cosino: private capture error: ", safeDiagnostic(detail)

proc captureError*(capture: RuntimeCapture, detail: string) =
  capture.failed = true
  if capture.errors.len < 16: capture.errors.add(safeDiagnostic(detail))
  echo "cosino: private capture error: ", safeDiagnostic(detail)

proc nativeStateHash*(sim: Sim): string =
  sha256($sim.tableStateJson()).toHex.toLowerAscii()

proc identities*(config: GameConfig): tuple[family, task: string] =
  ## A horizon/rule edit must not move a shared dealing stream across splits.
  ## 500 is the manifest's maximum requested hand count, independent of horizon.
  var root = config
  root.variant = vHoldem
  var stream = newJArray()
  for index in 0 ..< 500: stream.add(%pairDeck(root, index))
  let order = if config.seatOrder.len == config.players.len:
    config.seatOrder else: config.seatOrderFor()
  result.family = "cosino-dealing-stream-v1-" & sha256($(%*{
    "seats": config.players.len, "seating": order, "root_stream": stream
  })).toHex.toLowerAscii()
  var schedule = newJArray()
  for hand in 0 ..< config.hands:
    let pair = if config.duplicate: hand div 2 else: hand
    let deck = pairDeck(config, pair)
    # No burn cards: only these cards can affect this native hand.
    let count = config.players.len * config.variant.holeCount() +
      config.variant.boardSize()
    schedule.add(%*{"cards": deck[0 ..< count],
      "positions": config.positionsFor(hand), "pair": pair})
  result.task = "cosino-task-v1-" & sha256($(%*{
    "variant": $config.variant, "seats": config.players.len,
    "stack": config.startingStack, "ante": config.ante,
    "small_blind": config.smallBlind, "big_blind": config.bigBlind,
    "hands": config.hands, "duplicate": config.duplicate,
    "chip_race": config.chipRace, "seating": order,
    "opening_button": (if config.chipRace:
      order[((config.seed mod order.len) + order.len) mod order.len] else: order[0]),
    "schedule": schedule
  })).toHex.toLowerAscii()

proc destinationIdentity(value: string): string =
  if value.len == 0: return ""
  if value.isHttpCogameUri():
    let parsed = parseUri(value)
    # Signed query strings cannot make the same upload object a private destination.
    parsed.scheme.toLowerAscii() & "://" & parsed.hostname.toLowerAscii() &
      ":" & (if parsed.port.len > 0: parsed.port
        elif parsed.scheme.toLowerAscii() == "https": "443" else: "80") &
      decodeUrl(parsed.path).normalizedPath()
  else:
    pathFromCogameUri(value, CogameSaveTrajectoryUriEnv).absolutePath().normalizedPath()

proc newRuntimeCapture*(config: GameConfig, resultsUri, replayUri: string): RuntimeCapture =
  if getEnv(CogameSaveTrajectoryUriEnv).len == 0: return nil
  result = RuntimeCapture()
  try:
    for key in ["COWORLD_EPISODE_ID", "COWORLD_GAME_VERSION", "COWORLD_SOURCE_REVISION", "COWORLD_GAME_NAME"]:
      if not scalarUtf8(getEnv(key)):
        raise newException(ValueError, "non-Unicode private trajectory identity: " & key)
    let destination = destinationIdentity(getEnv(CogameSaveTrajectoryUriEnv))
    if destination == destinationIdentity(resultsUri) or
        destination == destinationIdentity(replayUri):
      raise newException(ValueError, "private trajectory destination collides with public results/replay")
    (result.family, result.task) = identities(config)
    result.trajectory = newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"),
      result.family, "cosino", getEnv("COWORLD_GAME_VERSION"),
      getEnv("COWORLD_SOURCE_REVISION"))
  except CatchableError as error:
    echo "cosino: private capture initialization failed: ", safeDiagnostic(error.msg)
    result = nil

proc beginDecision*(capture: RuntimeCapture, id, policy: string,
    observation, selection: JsonNode, preHash: string): CapturedDecision =
  if capture == nil: return nil
  try:
    if ($observation).len > MaxObservationEvidenceBytes:
      capture.captureError("private observation exceeds 131072 bytes; original omitted, no truncation")
      return nil
    result = CapturedDecision(id: id, policy: policy,
      observation: copy(observation))
    result.observation["scenario_family"] = %capture.family
    result.observation["task_identity"] = %capture.task
    result.observation["prompt_selection"] = copy(selection)
    result.observation["pre_native_sha256"] = %preHash
    result.observation["native_parsed_proposals"] = newJArray()
    result.observation["native_requests"] = newJArray()
  except CatchableError as error:
    capture.failed = true
    echo "cosino: private capture dispatch failed: ", error.msg

proc beginAttempt*(capture: CapturedDecision) =
  if capture == nil: return
  try:
    capture.attempts.add(newDecisionAttempt(capture.id & "-" &
      $(capture.attempts.len + 1), capture.policy, aoModel))
    capture.generated.add("")
  except CatchableError as error: capture.captureError(error.msg)

proc requested*(capture: CapturedDecision, body: string, headers: HttpHeaders) =
  if capture == nil: return
  try:
    if body.len > MaxRequestEvidenceBytes:
      capture.captureError("request evidence exceeds 65536 bytes; original omitted, no truncation")
      return
    let request = parseJson(body)
    var evidence = addr capture.attempts[^1]
    var safeHeaders = newJObject()
    for key in ["content-type", "anthropic-version", "X-Coworld-Player-Slot"]:
      if headers.contains(key): safeHeaders[key] = %headers[key]
    capture.observation["native_requests"].add(%*{
      "attempt_id": evidence.attemptId, "body_b64": encode(body),
      "raw_body": body, "headers": safeHeaders})
    evidence.request = copy(request)
    evidence.prompt = %*[{"role": "system", "content": request["system"]},
      {"role": "user", "content": request["messages"][0]["content"]}]
    if request.hasKey("model") and request["model"].kind == JString:
      evidence.model = some(request["model"].getStr())
    evidence.decoder = %*{"max_tokens": request["max_tokens"]}
    for key in ["temperature", "top_p", "top_k", "output_config", "thinking",
        "stop_sequences", "tools", "tool_choice"]:
      if request.hasKey(key): evidence.decoder[key] = copy(request[key])
  except CatchableError as error: capture.captureError(error.msg)

proc received*(capture: CapturedDecision, response: Response, latencyMs: int) =
  if capture == nil: return
  try:
    var evidence = addr capture.attempts[^1]
    evidence.latencyMs = some(float(latencyMs))
    evidence.responseComplete = some(true)
    evidence.responseReaderJoined = some(true) # synchronous curl.post has returned
    if response.code in 100 .. 599: evidence.httpStatus = some(response.code)
    if response.body.len > MaxResponseEvidenceBytes:
      capture.captureError("response evidence exceeds 65536 bytes; original omitted, no truncation")
    else:
      evidence.responseBodyB64 = some(encode(response.body))
      if scalarUtf8(response.body): evidence.rawResponse = %response.body
    var headers = initTable[string, string]()
    var headerBytes = 0
    for (key, value) in response.headers:
      headerBytes += key.len + value.len
      if headerBytes > MaxResponseHeaderEvidenceBytes: break
      headers[key] = value
    if headerBytes > MaxResponseHeaderEvidenceBytes:
      capture.captureError("response headers exceed 16384 bytes; map omitted, no truncation")
    else: evidence.responseHeaders = some(headers)
    if headerBytes <= MaxResponseHeaderEvidenceBytes:
      if response.headers.contains("X-Softmax-Llm-Call-Id"):
        evidence.platformCallId = some(response.headers["X-Softmax-Llm-Call-Id"])
      for key in ["request-id", "x-request-id"]:
        if response.headers.contains(key):
          evidence.providerRequestId = some(response.headers[key])
          break
    # HTTP errors and malformed replies still retain their received original bytes.
    try:
      if response.body.len > MaxResponseEvidenceBytes: return
      let payload = parseJson(response.body)
      if payload.kind != JObject: return # Error payloads need not have provider message shape.
      if payload.hasKey("model") and payload["model"].kind == JString:
        evidence.model = some(payload["model"].getStr())
      if payload.hasKey("stop_reason") and payload["stop_reason"].kind == JString:
        evidence.stopReason = some(payload["stop_reason"].getStr())
      if payload.hasKey("usage") and payload["usage"].kind == JObject:
        if payload["usage"].hasKey("input_tokens") and payload["usage"]["input_tokens"].kind == JInt and
            payload["usage"]["input_tokens"].getInt() >= 0:
          evidence.inputTokens = some(payload["usage"]["input_tokens"].getInt())
        if payload["usage"].hasKey("output_tokens") and payload["usage"]["output_tokens"].kind == JInt and
            payload["usage"]["output_tokens"].getInt() >= 0:
          evidence.outputTokens = some(payload["usage"]["output_tokens"].getInt())
    except CatchableError: discard
  except CatchableError as error: capture.captureError(error.msg)

proc transportFailed*(capture: CapturedDecision, detail: string, latencyMs: int) =
  if capture == nil: return
  try:
    capture.attempts[^1].responseComplete = some(false)
    capture.attempts[^1].responseReaderJoined = some(true)
    capture.attempts[^1].latencyMs = some(float(latencyMs))
    capture.attempts[^1].rejectionReason = some(safeDiagnostic(detail))
  except CatchableError as error: capture.captureError(error.msg)

proc replyText*(capture: CapturedDecision, text: string) =
  if capture == nil: return
  try:
    if text.len > MaxResponseEvidenceBytes:
      capture.captureError("reply text exceeds 65536 bytes; original omitted, no truncation")
      return
    capture.generated[^1] = text
    if scalarUtf8(text): capture.attempts[^1].response = %text
  except CatchableError as error: capture.captureError(error.msg)

proc rejectedAttempt*(capture: CapturedDecision, detail: string) =
  if capture == nil: return
  try: capture.attempts[^1].rejectionReason = some(safeDiagnostic(detail))
  except CatchableError as error: capture.captureError(error.msg)

proc parsedProposal*(capture: CapturedDecision, action: PlayerAction, say: string) =
  if capture == nil: return
  try:
    capture.observation["native_parsed_proposals"].add(%*{
      "attempt_id": capture.attempts[^1].attemptId,
      "action": $action.kind, "amount": action.amount, "say": say})
  except CatchableError as error: capture.captureError(error.msg)

proc strictRawObject(text: string): JsonNode =
  ## Reused from Garble's reviewed native-capture strictRawObject; native gameplay decoder is unchanged.
  if not scalarUtf8(text): raise newException(ValueError, "raw JSON is not UTF-8")
  let first = text.find('{')
  let last = text.rfind('}')
  if first < 0 or last < first: raise newException(ValueError, "no raw JSON object")
  let source = text[first .. last]
  var quoted = false
  var index = 0
  while index < source.len:
    let character = source[index]
    if quoted:
      if character == '\\':
        inc index
        if index >= source.len or source[index] notin {'"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u'}:
          raise newException(ValueError, "non-JSON string escape")
        if source[index] == 'u':
          for offset in 1 .. 4:
            if index + offset >= source.len or source[index + offset] notin {'0'..'9', 'a'..'f', 'A'..'F'}:
              raise newException(ValueError, "invalid Unicode escape")
          index += 4
      elif character == '"': quoted = false
      elif ord(character) < 32: raise newException(ValueError, "unescaped control character")
    elif character == '"': quoted = true
    elif character == '/': raise newException(ValueError, "JSON comments are forbidden")
    elif ord(character) < 32 and character notin {'\t', '\n', '\r'}:
      raise newException(ValueError, "non-JSON whitespace")
    inc index
  if quoted: raise newException(ValueError, "unterminated JSON string")
  var parser: JsonParser
  parser.open(newStringStream(source), "private raw action")
  defer: parser.close()
  discard parser.getTok()
  proc value(parser: var JsonParser, depth: int): JsonNode =
    if depth > 32: raise newException(ValueError, "raw JSON depth bound exceeded")
    case parser.tok
    of tkCurlyLe:
      result = newJObject()
      discard parser.getTok()
      if parser.tok == tkCurlyRi:
        discard parser.getTok()
        return
      while true:
        if parser.tok != tkString: raise newException(ValueError, "JSON object key required")
        let key = parser.a
        if not scalarUtf8(key): raise newException(ValueError, "non-Unicode decoded JSON key")
        if result.hasKey(key): raise newException(ValueError, "duplicate JSON key: " & key)
        discard parser.getTok()
        parser.eat(tkColon)
        result[key] = value(parser, depth + 1)
        if parser.tok == tkCurlyRi:
          discard parser.getTok()
          break
        parser.eat(tkComma)
    of tkBracketLe:
      result = newJArray()
      discard parser.getTok()
      if parser.tok == tkBracketRi:
        discard parser.getTok()
        return
      while true:
        result.add(value(parser, depth + 1))
        if parser.tok == tkBracketRi:
          discard parser.getTok()
          break
        parser.eat(tkComma)
    of tkString:
      if not scalarUtf8(parser.a): raise newException(ValueError, "non-Unicode decoded JSON string")
      result = %parser.a
      discard parser.getTok()
    of tkInt, tkFloat:
      let token = parser.a
      # Enforce JSON number spelling independently of Nim's permissive lexer.
      var cursor = 0
      if token[cursor] == '-': inc cursor
      if cursor >= token.len: raise newException(ValueError, "invalid JSON number")
      if token[cursor] == '0': inc cursor
      elif token[cursor] in {'1'..'9'}:
        while cursor < token.len and token[cursor] in {'0'..'9'}: inc cursor
      else: raise newException(ValueError, "invalid JSON number")
      if cursor < token.len and token[cursor] == '.':
        inc cursor
        let start = cursor
        while cursor < token.len and token[cursor] in {'0'..'9'}: inc cursor
        if cursor == start: raise newException(ValueError, "invalid JSON fraction")
      if cursor < token.len and token[cursor] in {'e', 'E'}:
        inc cursor
        if cursor < token.len and token[cursor] in {'+', '-'}: inc cursor
        let start = cursor
        while cursor < token.len and token[cursor] in {'0'..'9'}: inc cursor
        if cursor == start: raise newException(ValueError, "invalid JSON exponent")
      if cursor != token.len: raise newException(ValueError, "invalid JSON number")
      if parser.tok == tkInt: result = %parseBiggestInt(token)
      else:
        let number = parseFloat(token)
        if number.classify in {fcNan, fcInf, fcNegInf}:
          raise newException(ValueError, "non-finite raw JSON number")
        result = %number
      discard parser.getTok()
    of tkTrue, tkFalse:
      result = %(parser.tok == tkTrue)
      discard parser.getTok()
    of tkNull:
      result = newJNull()
      discard parser.getTok()
    else: raise newException(ValueError, "invalid raw JSON value")
  result = value(parser, 0)
  if parser.tok != tkEof or result.kind != JObject:
    raise newException(ValueError, "one raw JSON object required")

proc equalSupplied(raw, actual: JsonNode): bool =
  if raw.kind != actual.kind: return false
  if raw.kind == JObject:
    for key, value in raw:
      if not actual.hasKey(key) or not equalSupplied(value, actual[key]): return false
    return true
  if raw.kind == JArray:
    if raw.len != actual.len: return false
    for index in 0 ..< raw.len:
      if not equalSupplied(raw[index], actual[index]): return false
    return true
  raw == actual

proc unchangedReply(text: string, actual: JsonNode): bool =
  try: equalSupplied(strictRawObject(text), actual)
  except CatchableError: false

proc applied*(capture: RuntimeCapture, decision: CapturedDecision,
    seat: int, parsed: PlayerAction, say: string, events: seq[GameEvent],
    fallback, forcedFold: bool, origin, baseline, postHash: string) =
  if capture == nil or decision == nil: return
  try:
    var actual = %*{"action": "", "say": ""}
    var eventRows = newJArray()
    var count = 0
    for event in events:
      eventRows.add(event.eventToJson())
      if event.kind == evSay and event.seat == seat: actual["say"] = %event.text
      if event.kind == evAction and event.seat == seat:
        inc count
        actual["action"] = %($event.action)
        if event.action in [akBet, akRaise]: actual["amount"] = %event.amount
    if count != 1: raise newException(ValueError, "capture needs exactly one applied actor event")
    decision.observation["native_execution"] = %*{"events": eventRows,
      "events_sha256": sha256($eventRows).toHex.toLowerAscii(),
      "post_native_sha256": postHash,
      "parsed_action": {"action": $parsed.kind, "amount": parsed.amount, "say": say},
      "forced_fold": forcedFold, "origin": origin}
    var selected = none(string)
    var status = asMissing
    if fallback:
      status = asFallback
    elif origin == "model":
      status = asRejected
      if decision.attempts.len > 0:
        var evidence = addr decision.attempts[^1]
        evidence.parsedAction = copy(actual)
        evidence.accepted = not decision.failed and evidence.rejectionReason.isNone and
          evidence.responseComplete == some(true) and evidence.responseReaderJoined == some(true) and
          evidence.httpStatus.isSome and evidence.httpStatus.get() in 200 .. 299 and
          evidence.rawResponse.kind == JString and evidence.responseBodyB64.isSome and
          evidence.responseHeaders.isSome and
          unchangedReply(decision.generated[^1], actual)
        if evidence.accepted:
          selected = some(evidence.attemptId)
          status = asAccepted
        else:
          evidence.rejectionReason = some("strict JSON grammar/depth or supplied field/type/value differs from applied action")
    var originalAttempts = newJArray()
    for evidence in decision.attempts: originalAttempts.add(attemptEvidenceJson(evidence))
    let original = %*{"observation": decision.observation, "attempts": originalAttempts,
      "executed_action": actual, "actual_scripted": origin != "model" or fallback}
    if not scalarJson(original):
      # Evidence only: retain actual original bytes, never repair gameplay or a completion.
      let detail = "non-Unicode native evidence; original JSON bytes retained as base64; target excluded"
      decision.observation = %*{"capture_errors": [detail],
        "actual_scripted": origin != "model" or fallback,
        "invalid_native_evidence_json_b64": encode($original)}
      decision.attempts = @[]
      decision.failed = true
      selected = none(string)
      actual = newJNull()
      if status != asFallback: status = asRejected
    if decision.failed:
      capture.failed = true
      if decision.observation.hasKey("capture_errors"):
        for error in decision.observation["capture_errors"]:
          if capture.errors.len < 16: capture.errors.add(error.getStr())
    if capture.trajectory != nil:
      # Deliberately overcount duplicated JSON and selected prompt fields before retaining a row.
      var estimate = 4096 + 2 * ($decision.observation).len
      for evidence in decision.attempts: estimate += 2 * ($attemptEvidenceJson(evidence)).len
      if capture.evidenceBytes + estimate > MaxEpisodeEvidenceBytes - 4096:
        capture.captureError("episode evidence exceeds 24 MiB; decision omitted, no truncation")
        return
      capture.evidenceBytes += estimate
      capture.trajectory.recordDecision(decision.id, $seat, decision.observation,
        decision.attempts, selected, actual, status,
        fallbackOrigin = (if fallback: some(if forcedFold: "forced_fold" else: baseline) else: none(string)))
  except CatchableError as error:
    capture.captureError("applied evidence failed: " & error.msg)

proc finishCapture*(capture: RuntimeCapture, outcome: JsonNode) =
  if capture == nil: return
  try:
    if capture.trajectory == nil:
      raise newException(ValueError, "trajectory initialization failed")
    var privateOutcome = copy(outcome)
    var scores = outcome{"scores"}
    if not scalarJson(outcome):
      capture.captureError("non-Unicode native outcome; original JSON bytes retained as base64")
      privateOutcome = %*{"invalid_native_outcome_json_b64": encode($outcome)}
    if not scalarJson(scores): scores = newJNull()
    let status = if capture.failed: esFailed
      elif outcome{"reason"}.getStr() == "complete": esCompleted else: esTruncated
    if capture.failed:
      privateOutcome["capture_errors"] = %capture.errors
    capture.trajectory.finish(status, privateOutcome, scores)
    if capture.trajectory.eventsJsonl().len > MaxEpisodeEvidenceBytes:
      raise newException(ValueError, "private episode exceeds 24 MiB; publication omitted, no truncation")
    capture.trajectory.writeEventsToUri(getEnv(CogameSaveTrajectoryUriEnv))
  except CatchableError as error:
    # Evidence faults are visible but never change public results, replay, or gameplay.
    echo "cosino: private capture publication failed: ", safeDiagnostic(error.msg)
