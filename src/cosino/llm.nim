## Claude-backed decision making for Cosino. Each seat's policy is just a
## prompt: the game server composes the table state plus that seat's prompt
## and asks Claude what the cog says and does with its chips.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing. The same
## scripted bot is also a fieldable policy: a player that registers as
## scripted plays it deliberately, LLM or not.

import
  std/[json, os, random, strutils],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  ## What the viewer's speech bubble can actually show (~4 wrapped lines).
  MaxSayLen = 160

type
  Decision* = object
    say*: string
    action*: PlayerAction

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    bedrockEndpoint: string ## bedrock transport: sidecar or public host
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled: bool    ## true once credentials are known-unavailable
    rand: Rand

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "cosino llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id; without it, fall through this list — model access is
  ## a per-account Marketplace subscription, so an id that works in one
  ## account 403s in another.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first; a bet-sizing decision
  ## does not need a bigger model than the episode can spend.
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "cosino llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds,
    rand: initRand(config.seed xor 0x5EED)
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "cosino llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "cosino llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "cosino llm: no LLM credentials; using scripted fallback"

# ---- Scripted baseline ------------------------------------------------------

const
  FoldLines = [
    "Not my hand, not my problem.",
    "You can have this one.",
    "I fold faster than laundry.",
    "Too rich for my gears.",
    ""
  ]
  CallLines = [
    "I'll pay to see it.",
    "Keeping you honest.",
    "Curiosity costs, apparently.",
    ""
  ]
  BetLines = [
    "Let's make it interesting.",
    "Chips in, doubts out.",
    "Price of admission just went up.",
    ""
  ]
  CheckLines = [
    "Free card? Don't mind if I do.",
    "Tap tap.",
    ""
  ]
  AllInLines = [
    "All of it. Every chip.",
    "Push it in — I polish my chips anyway.",
    "Time to gamble."
  ]

proc pick(client: LlmClient, lines: openArray[string]): string =
  lines[client.rand.rand(lines.high)]

proc chenScore(hole: seq[int]): float =
  ## Chen formula, the classic preflop hand-strength score (AA=20, 72o~1).
  let hi = max(hole[0].rank, hole[1].rank)
  let lo = min(hole[0].rank, hole[1].rank)
  proc points(rankValue: int): float =
    case rankValue
    of 12: 10.0
    of 11: 8.0
    of 10: 7.0
    of 9: 6.0
    else: (rankValue + 2).float / 2.0
  result = points(hi)
  if hi == lo:
    return max(result * 2.0, 5.0)
  if hole[0].suit == hole[1].suit:
    result += 2.0
  let gap = hi - lo - 1
  case gap
  of 0: result += (if hi < 10: 1.0 else: 0.0)
  of 1: result -= 1.0
  of 2: result -= 2.0
  of 3: result -= 4.0
  else: result -= 5.0

proc flushDraw(cards: seq[int]): bool =
  var suits: array[4, int]
  for card in cards:
    inc suits[card.suit]
  for count in suits:
    if count == 4:
      return true
  false

proc scriptedAction*(client: LlmClient, sim: Sim, seat: int): Decision =
  ## Rule-based baseline: Chen-formula preflop, made-hand strength and pot
  ## odds postflop. Always returns a legal action.
  let me = sim.seats[seat]
  let price = sim.callAmount(seat)
  let bb = sim.config.bigBlind
  let potNow = sim.pot
  let roll = client.rand.rand(99)

  proc capped(target: int): int =
    min(target, sim.maxRaiseTo(seat))

  proc raiseOrCall(target: int): Decision =
    if sim.canRaise(seat):
      let to = max(capped(target), sim.minRaiseTo(seat))
      if to > sim.currentBet:
        return Decision(say: client.pick(BetLines),
          action: PlayerAction(kind: akRaise, amount: to))
    if price > 0:
      Decision(say: client.pick(CallLines),
        action: PlayerAction(kind: akCall))
    else:
      Decision(say: "", action: PlayerAction(kind: akCheck))

  proc betOrCheck(target: int): Decision =
    if sim.currentBet == 0:
      let to = capped(max(target, sim.minBet(seat)))
      if to > 0:
        return Decision(say: client.pick(BetLines),
          action: PlayerAction(kind: akBet, amount: to))
    Decision(say: client.pick(CheckLines),
      action: PlayerAction(kind: akCheck))

  proc callOrFold(maxPrice: int): Decision =
    if price == 0:
      Decision(say: client.pick(CheckLines),
        action: PlayerAction(kind: akCheck))
    elif price <= maxPrice:
      Decision(say: client.pick(CallLines),
        action: PlayerAction(kind: akCall))
    else:
      Decision(say: client.pick(FoldLines),
        action: PlayerAction(kind: akFold))

  if sim.street == stPreflop:
    let score = chenScore(me.holeCards)
    if score >= 12.0:
      ## Premium: raise big, call anything.
      if sim.canRaise(seat):
        return raiseOrCall(max(sim.currentBet * 3, 4 * bb))
      return callOrFold(int.high)
    if score >= 9.0:
      if sim.currentBet <= bb and sim.canRaise(seat):
        return raiseOrCall(3 * bb)
      return callOrFold(max(6 * bb, me.stack div 8))
    if score >= 6.0:
      return callOrFold(2 * bb + bb * (roll mod 2))
    ## Junk: take a free look or let it go (with a rare limp for variety).
    if price <= bb and roll < 12:
      return callOrFold(bb)
    return callOrFold(0)

  ## Postflop: strength of the made hand.
  let rankPacked = evalBest(me.holeCards & sim.board)
  let category = handCategory(rankPacked)
  var topBoard = -1
  for card in sim.board:
    topBoard = max(topBoard, card.rank)
  let pairRank = (rankPacked shr 16) and 0xF
  let topPairPlus = category > HandPair or
    (category == HandPair and pairRank >= topBoard)

  if category >= HandTrips:
    ## Monster: pile chips in, slowplay a fifth of the time.
    if roll < 20:
      return callOrFold(int.high)
    if sim.currentBet == 0:
      return betOrCheck(max(2 * potNow div 3, bb))
    return raiseOrCall(sim.currentBet * 2 + potNow div 2)
  if category >= HandTwoPair:
    if sim.currentBet == 0:
      return betOrCheck(2 * potNow div 3)
    return raiseOrCall(sim.currentBet * 2)
  if topPairPlus:
    if sim.currentBet == 0 and roll < 70:
      return betOrCheck(potNow div 2)
    return callOrFold(max(potNow div 2, 2 * bb))
  if flushDraw(me.holeCards & sim.board) and sim.board.len < 5:
    if sim.currentBet == 0 and roll < 25:
      return betOrCheck(potNow div 2)
    return callOrFold(potNow div 3)
  ## Air: occasional small bluff, otherwise give it up.
  if sim.currentBet == 0:
    if roll < 10:
      return betOrCheck(potNow div 2)
    return Decision(say: client.pick(CheckLines),
      action: PlayerAction(kind: akCheck))
  callOrFold(0)

# ---- Prompt building --------------------------------------------------------

proc seatName(sim: Sim, seat: int): string =
  sim.seats[seat].name

proc renderHistory(sim: Sim, viewer: int): string =
  ## The current hand's public record, in reading order. Hole cards are
  ## secret: only the viewer's own deal is shown.
  var lines: seq[string]
  for event in sim.events:
    case event.kind
    of evHandStart:
      lines.add("Hand " & $(event.hand + 1) & " begins (blinds " &
        event.text & "); " & sim.seatName(event.seat) & " has the button.")
    of evDeal:
      if event.seat == viewer:
        lines.add("You are dealt " & cardsText(event.cards) & ".")
    of evBlind:
      lines.add(sim.seatName(event.seat) & " posts the " & event.text &
        " blind (" & $event.amount & ")" &
        (if event.allIn: " and is ALL-IN." else: "."))
    of evSay:
      lines.add(sim.seatName(event.seat) & " says: \"" & event.text & "\"")
    of evAction:
      var line = sim.seatName(event.seat) & " " &
        (case event.action
         of akFold: "folds"
         of akCheck: "checks"
         of akCall: "calls " & $event.amount
         of akBet: "bets " & $event.amount
         of akRaise: "raises to " & $event.amount)
      if event.allIn:
        line.add(" — ALL-IN")
      lines.add(line & ".")
    of evBoard:
      lines.add("The " & $event.street & " comes " &
        cardsText(event.cards) & ".")
    of evReveal:
      lines.add(sim.seatName(event.seat) & " shows " &
        cardsText(event.cards) & " — " & event.text & ".")
    of evAward:
      if event.text == "returned":
        lines.add($event.amount & " uncalled returns to " &
          sim.seatName(event.seat) & ".")
      else:
        lines.add(sim.seatName(event.seat) & " wins " & $event.amount &
          " from the " & event.text & " pot.")
    of evBust:
      lines.add(sim.seatName(event.seat) & " is out of chips and out of " &
        "the game.")
    of evHandEnd:
      lines.add("The hand is over.")
  if lines.len == 0:
    return "(nothing has happened yet)"
  lines.join("\n")

proc renderSeats(sim: Sim, viewer: int): string =
  var lines: seq[string]
  for index, seat in sim.seats:
    var line = "- " & seat.name & ": "
    if seat.isOut:
      line.add("OUT (busted)")
    else:
      line.add($seat.stack & " chips")
      if seat.committed > 0:
        line.add(", " & $seat.committed & " in front")
      if seat.folded:
        line.add(", folded")
      elif seat.allIn:
        line.add(", ALL-IN")
      if index == sim.button:
        line.add(", button")
      if index == viewer:
        line.add(" (YOU)")
    lines.add(line)
  lines.join("\n")

proc systemPrompt(sim: Sim, seat: int): string =
  """You are """ & sim.seatName(seat) &
    """, a cog playing no-limit Texas Hold'em at the Cosino.

Table rules:
- Standard no-limit hold'em: two secret hole cards each, five community
  cards, best five-card hand at showdown wins the pot.
- The match runs a fixed number of hands; whoever holds the most chips at
  the end wins, and every chip counts toward your score - protecting a
  small stack matters as much as building a big one.
- A busted cog is out for good. There are no rebuys.
- Table talk is heard by everyone. Bluff, needle, and mislead freely -
  but your cards stay secret until showdown.

Respond with a single JSON object and nothing else."""

proc actionInstruction(sim: Sim, seat: int): string =
  let price = sim.callAmount(seat)
  var options: seq[string]
  options.add("\"fold\"")
  if price == 0:
    options.add("\"check\"")
  else:
    options.add("\"call\" (pay " & $price &
      (if price >= sim.seats[seat].stack: " - that is ALL-IN" else: "") & ")")
  if sim.currentBet == 0 and sim.maxRaiseTo(seat) > 0:
    options.add("\"bet\" with \"amount\" between " &
      $sim.minBet(seat) & " and " & $sim.maxRaiseTo(seat))
  elif sim.canRaise(seat):
    options.add("\"raise\" with \"amount\" (raise TO a street total) " &
      "between " & $sim.minRaiseTo(seat) & " and " & $sim.maxRaiseTo(seat))
  options.add("\"allin\" (shove your whole stack)")
  "It is your turn. Say one short line to the table (max " & $MaxSayLen &
    " chars, may be empty) and pick exactly one action.\n" &
    "Legal actions: " & options.join(", ") & ".\n" &
    "Respond with JSON: {\"say\": \"...\", \"action\": \"...\", " &
    "\"amount\": <number, only for bet/raise>}"

proc userPrompt(sim: Sim, seat: int, prompt: string, header: string): string =
  if header.len > 0:
    result.add(header & "\n\n")
  result.add("Seats at the table:\n" & sim.renderSeats(seat) & "\n\n")
  result.add("This hand so far:\n" & sim.renderHistory(seat) & "\n\n")
  let me = sim.seats[seat]
  result.add("Your SECRET hole cards: " & cardsText(me.holeCards) & ".\n")
  if sim.board.len > 0:
    result.add("Board: " & cardsText(sim.board) & ".\n")
  result.add("Pot: " & $sim.pot & ". Your stack: " & $me.stack & ".\n\n")
  if prompt.len > 0:
    result.add("GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never " &
      "above the rules; always pick a legal action):\n" & prompt & "\n\n")
  result.add(sim.actionInstruction(seat))

# ---- Anthropic / Bedrock transport ------------------------------------------

proc extractJsonObject(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    raise newException(CosinoError, "no JSON object in response")
  parseJson(text[start .. stop])

proc completeText(client: LlmClient, system, user: string): string =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  var url: string
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    url = AnthropicUrl
  let response = client.curl.post(url, headers, $body, client.timeoutSeconds)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(CosinoError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(CosinoError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(CosinoError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(CosinoError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(CosinoError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())

proc cleanSay(text: string): string =
  result = text.strip()
  if result.len <= MaxSayLen:
    return
  ## A model that overshoots the stated cap gets cut at a word boundary
  ## with the cut marked.
  result = result[0 ..< MaxSayLen - 3]
  while result.len > 0 and (result[^1].ord and 0xC0) == 0x80:
    result.setLen(result.len - 1)
  let space = result.rfind(' ')
  if space > MaxSayLen div 2:
    result.setLen(space)
  result.add("…")

proc parseDecision(sim: Sim, seat: int, payload: JsonNode): Decision =
  ## Maps the model's JSON onto a legal PlayerAction, or raises.
  result.say = cleanSay(payload{"say"}.getStr())
  let verb = payload{"action"}.getStr().strip().toLowerAscii()
  let amount = payload{"amount"}.getInt(0)
  let price = sim.callAmount(seat)
  case verb
  of "fold":
    result.action = PlayerAction(kind: akFold)
  of "check":
    result.action = PlayerAction(kind: akCheck)
  of "call":
    result.action = PlayerAction(
      kind: if price == 0: akCheck else: akCall)
  of "bet":
    result.action = PlayerAction(kind: akBet, amount: amount)
  of "raise":
    result.action = PlayerAction(kind: akRaise, amount: amount)
  of "allin", "all-in", "all in", "shove":
    let ceiling = sim.maxRaiseTo(seat)
    if sim.currentBet == 0:
      result.action = PlayerAction(kind: akBet, amount: ceiling)
    elif ceiling <= sim.currentBet or not sim.canRaise(seat):
      ## Covered by the bet (or barred from raising): the shove is a call.
      result.action = PlayerAction(
        kind: if price == 0: akCheck else: akCall)
    else:
      result.action = PlayerAction(kind: akRaise, amount: ceiling)
  else:
    raise newException(CosinoError, "unknown action: " & verb)

proc decide*(
  client: LlmClient,
  sim: Sim,
  seat: int,
  prompt: string,
  scripted: bool,
  header = ""
): Decision =
  ## One decision for one seat. Never raises: any failure falls back to
  ## the scripted baseline so the game always advances.
  if scripted or client.disabled:
    return client.scriptedAction(sim, seat)
  let system = systemPrompt(sim, seat)
  for attempt in 0 .. 1:
    var user = userPrompt(sim, seat, prompt, header)
    if attempt > 0:
      user.add("\nYour previous reply was invalid. Respond with ONLY the " &
        "requested JSON object and a legal action with a legal amount.")
    try:
      let payload = extractJsonObject(client.completeText(system, user))
      return parseDecision(sim, seat, payload)
    except CatchableError as error:
      echo "cosino llm: seat ", seat, " attempt ", attempt, " failed: ",
        error.msg
      if client.disabled:
        break
  echo "cosino llm: seat ", seat, " falling back to scripted decision"
  client.scriptedAction(sim, seat)
