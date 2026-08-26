## Shared types for Cosino. Pure: no IO, no globals.
##
## Three rungs of the same zero-sum imperfect-information game live behind
## one `Variant`: `kuhn` and `leduc` (fixed-limit, exactly solvable) and
## `holdem` (no-limit Texas Hold'em, heads-up or six-max).
##
## Hold'em plays in one of two match structures. The LADDER (default) resets
## every seat to `startingStack` each hand and deals duplicate mirrored pairs,
## so deal luck cancels and the score is cumulative net chips. The chip-race
## TABLE (`chipRace`) carries stacks between hands, busts are final, and the
## final chip share is the score — the classic Cosino cash table.

import std/[json, strutils, unicode]

const
  MaxSeats* = 6
  ## What the viewer's speech bubble can actually show: 6 wrapped lines of
  ## 300 px, measured in the 13 px font the bubble draws in
  ## (`BUBBLE_LINES`/`BUBBLE_MAX_W`, client/renderer.js, sized from THIS cap).
  ## Raise one without the other and a full-cap remark is cut on screen.
  MaxSayLen* = 120
  ## Server-side cap on the operator prompt a player delivers.
  MaxPromptLen* = 4000
  ## Table alias cap.
  MaxAliasLen* = 16
  ## Error text recorded on a fallback.
  MaxErrorLen* = 200

type
  CosinoError* = object of CatchableError

  Variant* = enum
    vKuhn = "kuhn"
    vLeduc = "leduc"
    vHoldem = "holdem"

  EndReason* = enum
    erComplete = "complete"
    erDeadline = "deadline"
    erBudget = "budget"

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    variant*: Variant
    startingStack*: int   ## the buy-in: every seat's stack at hand 0, and at
                          ## EVERY hand on the ladder rungs
    ante*: int            ## kuhn/leduc
    smallBlind*: int      ## holdem
    bigBlind*: int        ## holdem
    hands*: int           ## hand limit for the episode
    duplicate*: bool      ## hands 2k and 2k+1 share a deck, mirrored seating
    chipRace*: bool       ## holdem only: stacks carry between hands, busts
                          ## are final, the chip share is the score
    randomiseSeating*: bool
    seatOrder*: seq[int]  ## slot sitting at each table position
    sampled*: bool        ## true once the budget cap has been applied
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  Street* = enum
    stPreflop = "preflop"
    stFlop = "flop"
    stTurn = "turn"
    stRiver = "river"
    stShowdown = "showdown"

  ActionKind* = enum
    akFold = "fold"
    akCheck = "check"
    akCall = "call"
    akBet = "bet"
    akRaise = "raise"

  EventKind* = enum
    evHandStart = "handStart"
    evDeal = "deal"
    evAnte = "ante"
    evBlind = "blind"
    evSay = "say"
    evAction = "action"
    evBoard = "board"
    evReveal = "reveal"
    evAward = "award"
    evStackOff = "stackOff"
    evBust = "bust"
    evHandEnd = "handEnd"
    evHandVoid = "handVoid"
    evCalib = "calib"
    evAudit = "audit"
    evMatchEnd = "matchEnd"

  GameEvent* = object
    kind*: EventKind
    hand*: int          ## 0-based hand this event belongs to
    seat*: int          ## acting slot; -1 for table events
    cards*: seq[int]    ## deal / board / reveal cards
    best*: seq[int]     ## reveal events: the five cards making the hand
    amount*: int        ## chips moved (ante, blind, action delta, pot award)
    action*: ActionKind ## action events only
    allIn*: bool        ## action/blind left the actor with an empty stack
    street*: Street     ## street the event happened on
    stackAfter*: int    ## actor's stack after the event; -1 otherwise
    betAfter*: int      ## actor's street commitment after the event; -1 otherwise
    potAfter*: int      ## total chips in the pot after the event; -1 otherwise
    pair*: int          ## handStart: the duplicate pair index; -1 otherwise
    mirror*: bool       ## handStart: this is the mirror half of the pair
    text*: string       ## say text; blind kind ("small"/"big"); award label
    data*: JsonNode     ## handStart/handEnd/handVoid/calib/audit/matchEnd

  Seat* = object
    name*: string          ## anonymous table alias
    stack*: int
    committed*: int        ## chips put in on the current street
    totalCommitted*: int   ## chips put in over the whole hand
    holeCards*: seq[int]
    folded*: bool
    allIn*: bool
    acted*: bool           ## has acted on the current street
    mayRaise*: bool        ## betting is open to this seat right now
    isOut*: bool           ## chip race only: busted for good, sits out
    revealed*: bool        ## hole cards tabled at showdown (public now)
    handsWon*: int
    net*: int              ## cumulative net chips BEFORE the current hand

proc truncateRunes*(s: string, n: int): string =
  ## Truncates on RUNE boundaries, never bytes. A byte-boundary cut is how a
  ## replay renders in a browser and then fails a strict UTF-8/JSON parser.
  ## The result is at most `n` runes, the last being the ellipsis when the
  ## input overflowed.
  if n <= 0:
    return ""
  let runes = s.toRunes()
  if runes.len <= n:
    return s
  if n == 1:
    return "\u2026"
  $runes[0 ..< n - 1] & "\u2026"

proc seats*(config: GameConfig): int = config.players.len

proc betSizes*(variant: Variant, bigBlind: int): array[2, int] =
  ## Fixed wager size per betting round; Hold'em is no-limit and uses the
  ## big blind as its minimum bet instead.
  case variant
  of vKuhn: [1, 1]
  of vLeduc: [2, 4]
  of vHoldem: [bigBlind, bigBlind]

proc maxWagers*(variant: Variant): int =
  ## Wagers (an opening bet plus raises) allowed per betting round.
  case variant
  of vKuhn: 1
  of vLeduc: 2
  of vHoldem: high(int)

proc rounds*(variant: Variant): int =
  case variant
  of vKuhn: 1
  of vLeduc: 2
  of vHoldem: 4

proc lastStreet*(variant: Variant): Street =
  case variant
  of vKuhn: stPreflop
  of vLeduc: stFlop
  of vHoldem: stRiver

proc holeCount*(variant: Variant): int =
  case variant
  of vKuhn, vLeduc: 1
  of vHoldem: 2

proc boardSize*(variant: Variant): int =
  case variant
  of vKuhn: 0
  of vLeduc: 1
  of vHoldem: 5

proc fixedLimit*(variant: Variant): bool =
  variant in {vKuhn, vLeduc}

proc variantDefaults*(config: var GameConfig, variant: Variant) =
  config.variant = variant
  case variant
  of vKuhn:
    config.startingStack = 20
    config.ante = 1
    config.smallBlind = 0
    config.bigBlind = 0
    config.hands = 60
  of vLeduc:
    config.startingStack = 50
    config.ante = 1
    config.smallBlind = 0
    config.bigBlind = 0
    config.hands = 36
  of vHoldem:
    config.startingStack = 100
    config.ante = 0
    config.smallBlind = 1
    config.bigBlind = 2
    config.hands = 30

proc defaultGameConfig*(): GameConfig =
  result = GameConfig(
    seed: 0,
    duplicate: true,
    randomiseSeating: true,
    turnDelayMs: 250,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    # babel 0.1.2: 300 gets replies cut off at max_tokens.
    maxOutputTokens: 900,
    # 220 sequential decisions cannot afford a 45 s stall.
    llmTimeoutSeconds: 20
  )
  result.variantDefaults(vHoldem)

proc validate*(config: GameConfig) =
  if config.players.len < 2 or config.players.len > MaxSeats:
    raise newException(CosinoError,
      "cosino needs 2.." & $MaxSeats & " players")
  if config.startingStack < 2:
    raise newException(CosinoError, "startingStack must be at least 2")
  if config.hands < 1:
    raise newException(CosinoError, "hands must be at least 1")
  case config.variant
  of vKuhn, vLeduc:
    if config.players.len != 2:
      raise newException(CosinoError,
        $config.variant & " is a two-player game")
    if config.ante < 1:
      raise newException(CosinoError, $config.variant & " requires ante >= 1")
    if config.smallBlind != 0 or config.bigBlind != 0:
      raise newException(CosinoError,
        $config.variant & " has antes, not blinds")
    let cap = config.ante +
      config.variant.betSizes(0)[0] * config.variant.maxWagers() +
      config.variant.betSizes(0)[1] * config.variant.maxWagers()
    if config.startingStack < cap:
      raise newException(CosinoError,
        "startingStack too small for the fixed-limit wager cap")
  of vHoldem:
    if config.ante != 0:
      raise newException(CosinoError, "hold'em has blinds, not antes")
    if config.smallBlind < 1 or config.bigBlind <= config.smallBlind:
      raise newException(CosinoError, "blinds must satisfy 1 <= small < big")
    if config.startingStack < config.bigBlind * 2:
      raise newException(CosinoError, "startingStack too small for the blinds")
  if config.chipRace:
    if config.variant != vHoldem:
      raise newException(CosinoError, "the chip race is a hold'em table")
    if config.duplicate:
      raise newException(CosinoError,
        "the chip race carries stacks; duplicate pairs need identical starts")
  if config.seatOrder.len > 0:
    if config.seatOrder.len != config.players.len:
      raise newException(CosinoError, "seatOrder must cover every slot")
    var seen = newSeq[bool](config.players.len)
    for slot in config.seatOrder:
      if slot < 0 or slot >= config.players.len or seen[slot]:
        raise newException(CosinoError, "seatOrder must be a permutation")
      seen[slot] = true

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults. `variant` is read
  ## first so the rung's own defaults land before any explicit override.
  if configJson.strip().len == 0:
    config.validate()
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(CosinoError, "config must be a JSON object")
  if node.hasKey("variant"):
    let text = node["variant"].getStr()
    var variant: Variant
    try:
      variant = parseEnum[Variant](text)
    except ValueError:
      raise newException(CosinoError, "unknown variant: " & text)
    config.variantDefaults(variant)
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("startingStack"):
    config.startingStack = node["startingStack"].getInt()
  if node.hasKey("ante"):
    config.ante = node["ante"].getInt()
  if node.hasKey("smallBlind"):
    config.smallBlind = node["smallBlind"].getInt()
  if node.hasKey("bigBlind"):
    config.bigBlind = node["bigBlind"].getInt()
  if node.hasKey("hands"):
    config.hands = node["hands"].getInt()
  if node.hasKey("duplicate"):
    config.duplicate = node["duplicate"].getBool()
  if node.hasKey("chipRace"):
    config.chipRace = node["chipRace"].getBool()
    ## The default config is a ladder table; an explicit duplicate:true next
    ## to chipRace:true is still a contradiction validate() rejects.
    if config.chipRace and not node.hasKey("duplicate"):
      config.duplicate = false
  if node.hasKey("randomiseSeating"):
    config.randomiseSeating = node["randomiseSeating"].getBool()
  if node.hasKey("seatOrder"):
    config.seatOrder = @[]
    for slot in node["seatOrder"]:
      config.seatOrder.add(slot.getInt())
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  config.validate()
