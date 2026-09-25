## Claude-backed decisions for prompt policies. The game server composes the
## table state plus that seat's prompt and asks Claude what the cog says and
## does with its chips.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal scripted
## baseline immediately (no retries, no network waits) so offline
## certification still completes — this fallback is load-bearing. The same
## baselines are fieldable policies: PLAYER_SCRIPTED=house|rock.

import
  std/[json, math, monotimes, os, random, strutils, times],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  ## Raised by 500 ms for the rest of the episode on a 429.
  ThrottleBumpMs = 500

type
  Baseline* = enum
    blHouse = "house"
    blRock = "rock"

  Decision* = object
    say*: string
    action*: PlayerAction
    fallback*: bool    ## the scripted baseline played instead of the model
    error*: string     ## why, rune-truncated for the replay

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
    disabled: bool          ## true once credentials are known-unavailable
    spacingMs*: int         ## wall-clock floor between decision starts
    lastCall: MonoTime
    rand: Rand

proc parseBaseline*(text: string): Baseline =
  ## Any non-empty value that is not `rock` means `house`.
  if text.strip().toLowerAscii() == "rock": blRock else: blHouse

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
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL pins
  ## a single id. `us.anthropic.claude-sonnet-4-6` is deliberately ABSENT: it
  ## times out on every sidecar call (raid, 2026-08-23), and one throttle
  ## cascades into scripted fallbacks for the rest of the episode.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
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

proc newScriptedClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds,
    disabled: true,
    spacingMs: DecisionSpacingMs,
    lastCall: getMonoTime(),
    rand: initRand(int64(config.seed) xor 0x5EED)
  )

proc newLlmClient*(config: GameConfig): LlmClient =
  result = newScriptedClient(config)
  result.disabled = false
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

proc credentialled*(client: LlmClient): bool =
  not client.disabled and client.transport != ltNone

# ---- Scripted baselines -----------------------------------------------------

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

proc fixedMove(client: LlmClient, sim: Sim, seat: int, wager: bool,
    fold: bool): Decision =
  ## The three always-legal moves of a fixed-limit rung, in preference order.
  let price = sim.callAmount(seat)
  if wager:
    if sim.canBet(seat):
      return Decision(say: client.pick(BetLines),
        action: PlayerAction(kind: akBet, amount: sim.minBet(seat)))
    if sim.canRaise(seat):
      return Decision(say: client.pick(BetLines),
        action: PlayerAction(kind: akRaise, amount: sim.minRaiseTo(seat)))
  if price > 0:
    if fold:
      return Decision(say: client.pick(FoldLines),
        action: PlayerAction(kind: akFold))
    return Decision(say: client.pick(CallLines),
      action: PlayerAction(kind: akCall))
  Decision(say: client.pick(CheckLines), action: PlayerAction(kind: akCheck))

proc kuhnAction(client: LlmClient, sim: Sim, seat: int,
    baseline: Baseline): Decision =
  ## `house` is the exact alpha = 1/6 Kuhn equilibrium (measured
  ## exploitability 0); `rock` bets and calls only the king.
  let card = sim.seats[seat].holeCards[0].rank
  let jack = card == 9
  let queen = card == 10
  let king = card == 11
  let position = sim.posOf[seat]
  let facing = sim.callAmount(seat) > 0
  let roll = client.rand.rand(1.0)
  if baseline == blRock:
    if facing:
      return client.fixedMove(sim, seat, wager = false, fold = not king)
    return client.fixedMove(sim, seat, wager = king, fold = false)
  if position == 0:
    if facing:
      ## Checked, then faced a bet: fold J, call Q half the time, call K.
      let callProb = if jack: 0.0 elif queen: 0.5 else: 1.0
      return client.fixedMove(sim, seat, wager = false, fold = roll >= callProb)
    let betProb = if jack: 1.0 / 6.0 elif queen: 0.0 else: 0.5
    return client.fixedMove(sim, seat, wager = roll < betProb, fold = false)
  if facing:
    let callProb = if jack: 0.0 elif queen: 1.0 / 3.0 else: 1.0
    return client.fixedMove(sim, seat, wager = false, fold = roll >= callProb)
  let betProb = if jack: 1.0 / 3.0 elif queen: 0.0 else: 1.0
  client.fixedMove(sim, seat, wager = roll < betProb, fold = false)

proc leducAction(client: LlmClient, sim: Sim, seat: int,
    baseline: Baseline): Decision =
  let card = sim.seats[seat].holeCards[0].rank
  let boardRank = if sim.board.len > 0: sim.board[0].rank else: -1
  let paired = boardRank >= 0 and boardRank == card
  let jack = card == 9
  let queen = card == 10
  let king = card == 11
  let facing = sim.callAmount(seat) > 0
  let faced = if facing: sim.wagers else: 0
  let roll = client.rand.rand(1.0)
  if baseline == blRock:
    ## Never opens unless paired with the board; calls only paired or K.
    if facing:
      return client.fixedMove(sim, seat, wager = false,
        fold = not (paired or king))
    return client.fixedMove(sim, seat, wager = paired, fold = false)
  if sim.round == 0:
    case faced
    of 0:
      let betProb = if king: 1.0 elif queen: 1.0 / 3.0 else: 0.0
      return client.fixedMove(sim, seat, wager = roll < betProb, fold = false)
    of 1:
      if king and sim.canRaise(seat):
        return client.fixedMove(sim, seat, wager = true, fold = false)
      return client.fixedMove(sim, seat, wager = false, fold = jack)
    else:
      return client.fixedMove(sim, seat, wager = false, fold = not king)
  case faced
  of 0:
    let betProb = if paired: 1.0 elif king: 0.5 else: 0.0
    client.fixedMove(sim, seat, wager = roll < betProb, fold = false)
  of 1:
    if paired and sim.canRaise(seat):
      return client.fixedMove(sim, seat, wager = true, fold = false)
    let call = paired or king or (queen and boardRank == 9)
    client.fixedMove(sim, seat, wager = false, fold = not call)
  else:
    client.fixedMove(sim, seat, wager = false, fold = not (paired or king))

proc holdemAction(client: LlmClient, sim: Sim, seat: int,
    baseline: Baseline): Decision =
  ## `house` is cosino's Chen-formula bot verbatim; `rock` is its
  ## tight-passive cousin, which never bluffs.
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
    if sim.canBet(seat):
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

  let score = chenScore(me.holeCards)
  if sim.street == stPreflop:
    if baseline == blRock:
      if score >= 12.0 and sim.currentBet <= bb and sim.canRaise(seat):
        return raiseOrCall(3 * bb)
      if score >= 9.0:
        return callOrFold(4 * bb)
      return callOrFold(0)
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

  if baseline == blRock:
    if category >= HandTwoPair:
      if sim.currentBet == 0:
        return betOrCheck(2 * potNow div 3)
      return callOrFold(int.high)
    if topPairPlus:
      return callOrFold(potNow div 3)
    return callOrFold(0)

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

proc scriptedAction*(client: LlmClient, sim: Sim, seat: int,
    baseline = blHouse): Decision =
  ## Always returns a legal action, at every rung and every seat count.
  case sim.config.variant
  of vKuhn: client.kuhnAction(sim, seat, baseline)
  of vLeduc: client.leducAction(sim, seat, baseline)
  of vHoldem: client.holdemAction(sim, seat, baseline)

# ---- Prompt building --------------------------------------------------------

proc seatName(sim: Sim, seat: int): string =
  sim.seats[seat].name

proc variantName*(variant: Variant, seats: int): string =
  case variant
  of vKuhn: "Kuhn poker"
  of vLeduc: "Leduc hold'em"
  of vHoldem:
    if seats <= 2: "heads-up no-limit Texas Hold'em"
    else: "six-max no-limit Texas Hold'em"

proc variantRules*(config: GameConfig): string =
  case config.variant
  of vKuhn:
    "- Deck: three cards only, J, Q and K. One secret card each.\n" &
    "- Both seats ante " & $config.ante &
      ". There is exactly ONE betting round.\n" &
    "- The bet size is fixed at 1 and AT MOST ONE wager is allowed in the\n" &
    "  round: someone may bet 1, and the other may then only call or fold.\n" &
    "  There are no raises.\n" &
    "- Position 0 (the button) acts first.\n" &
    "- Showdown: the higher card wins. There are no ties.\n" &
    "- Net swings are +/-1 (uncontested or a single-bet pot) or +/-2 (a\n" &
    "  called bet)."
  of vLeduc:
    "- Deck: six cards, J, Q and K in two suits. One secret card each.\n" &
    "- Both seats ante " & $config.ante & ". There are TWO betting rounds.\n" &
    "- Round 1 wagers are 2 chips; round 2 wagers are 4 chips. AT MOST TWO\n" &
    "  wagers per round (an opening bet and one raise); facing the second\n" &
    "  wager you may only call or fold.\n" &
    "- If both seats are still in after round 1, ONE public board card is\n" &
    "  turned.\n" &
    "- Position 0 acts first in BOTH rounds.\n" &
    "- Showdown: a private card matching the board's rank is a PAIR and beats\n" &
    "  any unpaired hand; otherwise the higher card wins; equal ranks split.\n" &
    "- A fold forfeits everything you have committed."
  of vHoldem:
    "- Standard no-limit Texas Hold'em: two secret hole cards each, five\n" &
    "  community cards, best five-card hand at showdown wins the pot.\n" &
    "- Blinds are " & $config.smallBlind & "/" & $config.bigBlind &
      " and never escalate. Heads-up, the button posts\n" &
    "  the small blind and acts first preflop, last afterwards.\n" &
    "- Full no-limit betting: fold / check / call / bet / raise / all-in.\n" &
    "  Min-raise rules apply; a short all-in does not re-open the betting.\n" &
    "- Side pots form per commitment level; split pots share evenly."

proc systemPrompt*(sim: Sim, seat: int): string =
  let config = sim.config
  "You are " & sim.seatName(seat) & ", a cog playing " &
    variantName(config.variant, sim.seats.len) &
    (if config.chipRace: " at the Cosino table.\n\n"
     else: " at the Cosino ladder.\n\n") &
    variantRules(config) & "\n\n" &
    (if config.chipRace:
      "- Every seat bought in ONCE for " & $config.startingStack &
      " chips. Stacks carry from hand to hand,\n" &
      "  a seat that loses its last chip is OUT for good (no rebuys), and " &
      "your score is your final\n" &
      "  CHIP SHARE — so protecting a short stack counts as much as " &
      "building a tower.\n"
     else:
      "- Every hand starts with both/all seats on " & $config.startingStack &
      " chips. Your score is your\n" &
      "  cumulative NET chips across the match, so a chip saved counts " &
      "exactly as much as a chip won.\n") &
    "- Table talk is public and free. Bluff, needle and mislead — but your " &
    "cards stay secret until\n  showdown.\n" &
    "- Pick exactly one action from the legal list you are given, with an " &
    "amount inside the stated\n  range. An illegal answer is replaced by a " &
    "house baseline move, which is never what you want.\n\n" &
    "Reply with a single JSON object and NOTHING else. Your reply MUST " &
    "begin with the character `{`."

proc renderHistory(sim: Sim, viewer: int): string =
  ## The current hand's public record, in reading order. Hole cards are
  ## secret: only the viewer's own deal is shown.
  var lines: seq[string]
  for event in sim.events:
    case event.kind
    of evHandStart:
      lines.add("Hand " & $(event.hand + 1) & " begins (" & event.text &
        "); " & sim.seatName(event.seat) & " has the button.")
    of evDeal:
      if event.seat == viewer:
        lines.add("You are dealt " & cardsText(event.cards) & ".")
    of evAnte:
      lines.add(sim.seatName(event.seat) & " antes " & $event.amount & ".")
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
      let label =
        if sim.config.variant == vLeduc: "board card"
        else: $event.street
      lines.add("The " & label & " comes " & cardsText(event.cards) & ".")
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
      lines.add(sim.seatName(event.seat) &
        " is BUSTED and out of the match.")
    of evStackOff, evHandEnd, evHandVoid, evCalib, evAudit, evMatchEnd:
      discard
  if lines.len == 0:
    return "(nothing has happened yet)"
  lines.join("\n")

proc renderSeats(sim: Sim, viewer: int): string =
  var lines: seq[string]
  for index, seat in sim.seats:
    var line = "- " & seat.name & ": " & $seat.stack & " chips"
    if seat.committed > 0:
      line.add(", " & $seat.committed & " in front")
    if seat.isOut:
      line.add(", BUSTED OUT")
    elif seat.folded:
      line.add(", folded")
    elif seat.allIn:
      line.add(", ALL-IN")
    if index == sim.button:
      line.add(", button")
    if index == viewer:
      line.add(" (YOU)")
    lines.add(line)
  lines.join("\n")

proc renderStandings(sim: Sim): string =
  var lines: seq[string]
  for seat in sim.seats:
    lines.add("- " & seat.name & ": net " &
      (if seat.net >= 0: "+" else: "") & $seat.net & " chips, " &
      $seat.handsWon & " hands won")
  lines.join("\n")

proc actionInstruction(sim: Sim, seat: int): string =
  ## The precomputed legal action set with exact amounts, computed by the same
  ## predicates `applyAction` validates with. Precomputing this is what stops
  ## formal-output fallbacks (escrow, 2026-08-23).
  let price = sim.callAmount(seat)
  var options: seq[string]
  options.add("\"fold\"")
  if price == 0:
    options.add("\"check\"")
  else:
    options.add("\"call\" (pay " & $price &
      (if price >= sim.seats[seat].stack: " — that is ALL-IN" else: "") & ")")
  if sim.config.variant.fixedLimit:
    if sim.canBet(seat):
      options.add("\"bet\" (the wager is fixed at " & $sim.minBet(seat) &
        "; \"amount\" is ignored)")
    elif sim.canRaise(seat):
      options.add("\"raise\" (fixed, to a street total of " &
        $sim.minRaiseTo(seat) & "; \"amount\" is ignored)")
  else:
    if sim.canBet(seat):
      options.add("\"bet\" with \"amount\" between " &
        $sim.minBet(seat) & " and " & $sim.maxRaiseTo(seat))
    elif sim.canRaise(seat):
      options.add("\"raise\" with \"amount\" (raise TO a street total) " &
        "between " & $sim.minRaiseTo(seat) & " and " & $sim.maxRaiseTo(seat))
    options.add("\"allin\" (shove your whole stack)")
  "It is your turn. Say one short line to the table (max " & $MaxSayLen &
    " characters, may be empty) and pick exactly one action.\n" &
    "Legal actions: " & options.join(", ") & ".\n" &
    "Respond with JSON: {\"say\": \"...\", \"action\": \"...\", " &
    "\"amount\": <number, only for bet/raise>}"

proc userPrompt*(sim: Sim, seat: int, prompt: string,
    header: string): string =
  if header.len > 0:
    result.add(header & "\n\n")
  result.add("Standings (cumulative net chips):\n" & sim.renderStandings() &
    "\n\n")
  result.add("Seats at the table:\n" & sim.renderSeats(seat) & "\n\n")
  result.add("This hand so far:\n" & sim.renderHistory(seat) & "\n\n")
  let me = sim.seats[seat]
  result.add("Your SECRET card" & (if me.holeCards.len > 1: "s" else: "") &
    ": " & cardsText(me.holeCards) & ".\n")
  if sim.board.len > 0:
    result.add("Board: " & cardsText(sim.board) & ".\n")
  result.add("Pot: " & $sim.pot & ". Your stack: " & $me.stack & ".\n\n")
  if prompt.len > 0:
    result.add("GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never " &
      "above the rules; always pick a legal action):\n" & prompt & "\n\n")
  result.add(sim.actionInstruction(seat))

# ---- Anthropic / Bedrock transport ------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences
  ## and trailing prose.
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
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    url = AnthropicUrl
  ## `output_config.effort` is NOT sent: Haiku 4.5 rejects it.
  let response = client.curl.post(url, headers, $body, client.timeoutSeconds)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(CosinoError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(CosinoError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    ## No retry on a throttle: take the scripted move immediately and slow the
    ## whole episode down for the rest of its life.
    client.spacingMs += ThrottleBumpMs
    let detail = response.body[0 .. min(response.body.high, 300)]
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

proc parseDecision*(sim: Sim, seat: int, payload: JsonNode): Decision =
  ## Maps the model's JSON onto a legal PlayerAction, or raises.
  result.say = truncateRunes(payload{"say"}.getStr().strip(), MaxSayLen)
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

type
  ApplyOutcome* = object
    fallbacks*: int
    forcedFolds*: int

proc applyDecision*(
  client: LlmClient,
  sim: var Sim,
  seat: int,
  decision: Decision,
  baseline = blHouse,
  baselineFor: proc (sim: Sim, seat: int): PlayerAction {.closure.} = nil
): ApplyOutcome =
  ## Records the table talk and plays the action, degrading twice so the hand
  ## can never stall: an illegal model action falls back to the seat's
  ## scripted baseline, and a baseline the engine also rejects folds, which is
  ## always legal. `baselineFor` is a seam for the tests.
  if decision.fallback:
    inc result.fallbacks
  sim.recordSay(seat, decision.say)
  try:
    sim.applyAction(seat, decision.action)
    return
  except CosinoError as error:
    echo "cosino: action rejected (", error.msg, "); using the baseline"
    inc result.fallbacks
  let fallback =
    if baselineFor.isNil: client.scriptedAction(sim, seat, baseline).action
    else: baselineFor(sim, seat)
  try:
    sim.applyAction(seat, fallback)
    return
  except CosinoError as inner:
    echo "cosino: baseline rejected too (", inner.msg, "); folding"
    inc result.forcedFolds
  sim.applyAction(seat, PlayerAction(kind: akFold))

proc waitForSpacing(client: LlmClient) =
  ## Wall-clock floor from decision start to decision start; the Bedrock
  ## sidecar caps an episode at 30 requests per minute.
  let elapsed = (getMonoTime() - client.lastCall).inMilliseconds.int
  if elapsed < client.spacingMs:
    sleep(client.spacingMs - elapsed)
  client.lastCall = getMonoTime()

proc decide*(
  client: LlmClient,
  sim: Sim,
  seat: int,
  prompt: string,
  scripted: bool,
  baseline = blHouse,
  header = ""
): Decision =
  ## One decision for one seat. Never raises: any failure degrades to the
  ## scripted baseline so the game always advances.
  if scripted or client.disabled:
    return client.scriptedAction(sim, seat, baseline)
  client.waitForSpacing()
  let system = systemPrompt(sim, seat)
  var lastError = ""
  for attempt in 0 .. 1:
    var user = userPrompt(sim, seat, prompt, header)
    if attempt > 0:
      user.add("\nYour previous reply was invalid. Respond with ONLY the " &
        "requested JSON object and a legal action with a legal amount.")
    try:
      let payload = extractJsonObject(client.completeText(system, user))
      return parseDecision(sim, seat, payload)
    except CatchableError as error:
      lastError = error.msg
      echo "cosino llm: seat ", seat, " attempt ", attempt, " failed: ",
        error.msg
      if client.disabled or "429" in error.msg:
        break
  echo "cosino llm: seat ", seat, " falling back to scripted decision"
  result = client.scriptedAction(sim, seat, baseline)
  result.fallback = true
  result.error = truncateRunes(lastError, MaxErrorLen)
