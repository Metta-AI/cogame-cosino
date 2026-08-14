import std/[json, strutils]

type
  CosinoError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    startingStack*: int   ## chips each seat buys in for
    smallBlind*: int
    bigBlind*: int
    hands*: int           ## hand limit for the episode
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
    evBlind = "blind"
    evSay = "say"
    evAction = "action"
    evBoard = "board"
    evReveal = "reveal"
    evAward = "award"
    evHandEnd = "handEnd"
    evBust = "bust"

  GameEvent* = object
    kind*: EventKind
    hand*: int          ## 0-based hand this event belongs to
    seat*: int          ## acting seat; -1 for board/handEnd events
    cards*: seq[int]    ## deal / board / reveal cards
    amount*: int        ## chips moved (blind, action delta, pot award)
    action*: ActionKind ## action events only
    allIn*: bool        ## action/blind left the actor with an empty stack
    street*: Street     ## street the event happened on
    stackAfter*: int    ## actor's stack after the event; -1 otherwise
    betAfter*: int      ## actor's street commitment after the event; -1 otherwise
    potAfter*: int      ## total chips in the pot after the event; -1 otherwise
    text*: string       ## say text; blind kind ("small"/"big"); award label

  Seat* = object
    name*: string          ## anonymous table alias
    stack*: int
    committed*: int        ## chips put in on the current street
    totalCommitted*: int   ## chips put in over the whole hand
    holeCards*: seq[int]
    folded*: bool
    allIn*: bool
    isOut*: bool           ## busted before this hand: no chips, sits out
    acted*: bool           ## has acted on the current street
    mayRaise*: bool        ## betting is open to this seat right now
    handsWon*: int

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    startingStack: 100,
    smallBlind: 1,
    bigBlind: 2,
    hands: 30,
    turnDelayMs: 900,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 300,
    llmTimeoutSeconds: 45
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(CosinoError, "config must be a JSON object")
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
  if node.hasKey("smallBlind"):
    config.smallBlind = node["smallBlind"].getInt()
  if node.hasKey("bigBlind"):
    config.bigBlind = node["bigBlind"].getInt()
  if node.hasKey("hands"):
    config.hands = node["hands"].getInt()
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
  if config.bigBlind < 2 or config.smallBlind < 1 or
      config.smallBlind >= config.bigBlind:
    raise newException(CosinoError, "blinds must satisfy 1 <= small < big")
  if config.startingStack < config.bigBlind * 2:
    raise newException(CosinoError, "startingStack too small for the blinds")
