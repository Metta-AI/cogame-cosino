## Cosino game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - shared table renderer
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol (prompt delivery)
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol (cosino.player.v1), all JSON text frames:
##   game -> player: {"type":"welcome","slot":N,"name":...}
##                   {"type":"state",...} after every event batch
##                   {"type":"final","scores":[...],"win":[...]}
##   player -> game: {"type":"prompt","prompt":"...","scripted":bool}
##                   (max 4000 chars; scripted:true plays the built-in
##                   rule-based baseline for that seat)

import
  std/[json, locks, os, sets, strutils, tables, times],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  MaxPromptLen = 4000
  ReplayVersion = 1

type
  GameState = object
    config: GameConfig
    match: Match
    prompts: seq[string]
    scripted: seq[bool]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous table names; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of the aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.match.allEvents():
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.match.sim.tableStateJson()
  result["type"] = %"state"
  result["game"] = %"cosino"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["hands"] = %gs.config.hands
  result["handsPlayed"] = %gs.match.handsPlayed
  result["startingStack"] = %gs.config.startingStack
  result["smallBlind"] = %gs.config.smallBlind
  result["bigBlind"] = %gs.config.bigBlind
  result["started"] = %gs.started
  result["done"] = %gs.match.done
  result["connected"] = connected

proc redactCards(snapshot: JsonNode, slot: int) =
  ## Hole cards are secret: a player sees only its own, plus whatever the
  ## showdown made public (revealed seats and reveal events survive the
  ## redaction). The global viewer keeps everything — that is the
  ## spectator's edge.
  for index, seat in snapshot["seats"].getElems():
    if index != slot and not seat{"revealed"}.getBool(false):
      seat["cards"] = newJArray()
  var visible = newJArray()
  for event in snapshot["events"]:
    if event{"kind"}.getStr() == "deal" and event{"seat"}.getInt() != slot:
      continue
    visible.add(event)
  snapshot["events"] = visible

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    var observation = gs.snapshotJson()
    observation["slot"] = %slot
    observation.redactCards(slot)
    ## Players never learn who is behind a seat — that is the whole point
    ## of the aliases — so the policy-name map is spectator-only.
    observation.delete("policyNames")
    socket.send($observation)

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError,
        "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayPayload(gs: GameState, results: JsonNode): string =
  var names = newJArray()
  for seat in gs.match.sim.seats:
    names.add(%seat.name)
  var events = newJArray()
  for event in gs.match.allEvents():
    events.add(event.eventToJson())
  $ %*{
    "protocol": "cosino.replay.v" & $ReplayVersion,
    "names": names,
    "policyNames": gs.policyNamesJson(),
    "config": {
      "startingStack": gs.config.startingStack,
      "smallBlind": gs.config.smallBlind,
      "bigBlind": gs.config.bigBlind,
      "hands": gs.config.hands,
      "sampled": true,
      "seed": gs.config.seed
    },
    "events": events,
    "results": results
  }

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One table-state object per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.frameStateJson())

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.match.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection.
    ## Results carry POLICY names for the platform, but the final frame
    ## goes to the player sockets — hand them the table aliases instead.
    var aliasNames = newJArray()
    for seat in state.match.sim.seats:
      aliasNames.add(%seat.name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "win": results["win"],
      "names": aliasNames,
      "stacks": results["stacks"],
      "handsWon": results["handsWon"],
      "handsPlayed": results["handsPlayed"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "cosino: writing results and replay"
  writeArtifact(
    runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD"
  )
  writeArtifact(
    runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD"
  )
  sleep(500)
  echo "cosino: episode complete, shutting down"
  quit(0)

const PlayBudgetFraction* = 0.6
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects, and writing the artifacts — the part
  ## that must never be the thing that runs out of time.

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let deadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < deadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "cosino: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    ## The platform hands the container its own kill time. Play inside a
    ## fraction of it so results and the replay are written with room to
    ## spare — an episode that overruns is discarded whole.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    let timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "cosino: episode timeout ", timeoutSeconds.int, "s; playing until ",
        (timeoutSeconds * PlayBudgetFraction).int, "s"

    proc matchHeader(): string =
      "Hand " & $(state.match.sim.hand + 1) & " of " &
        $state.config.hands & " in the match."

    while true:
      var simCopy: Sim
      var seat: int
      var seatPrompt: string
      var seatScripted: bool
      var header: string
      withLock stateLock:
        if state.match.done:
          break
        simCopy = state.match.sim
        seat = state.match.sim.actingSeat
        if seat < 0:
          ## Should not happen: a live hand always has an actor.
          echo "cosino: no acting seat on a live hand; ending match"
          state.match.endMatchEarly()
          break
        seatPrompt = state.prompts[seat]
        seatScripted = state.scripted[seat]
        header = matchHeader()

      ## The slow part (Claude) runs outside the lock on a snapshot; only
      ## this thread mutates the match, so the snapshot cannot go stale.
      let decision = client.decide(simCopy, seat, seatPrompt,
        scripted = seatScripted, header = header)

      var handEnded = false
      withLock stateLock:
        state.match.sim.recordSay(seat, decision.say)
        try:
          state.match.sim.applyAction(seat, decision.action)
        except CosinoError as error:
          echo "cosino: llm action rejected (", error.msg,
            "); using scripted fallback"
          let fallback = client.scriptedAction(state.match.sim, seat)
          try:
            state.match.sim.applyAction(seat, fallback.action)
          except CosinoError as inner:
            ## Folding is always legal; the hand must advance.
            echo "cosino: fallback rejected too (", inner.msg, "); folding"
            state.match.sim.applyAction(seat,
              PlayerAction(kind: akFold))
        if state.match.sim.done:
          state.match.finishHand()
          handEnded = true
        state.broadcastLocked()

      if config.turnDelayMs > 0:
        sleep(config.turnDelayMs)

      if handEnded:
        var done = false
        withLock stateLock:
          done = state.match.done
          if not done and playDeadline > 0.0 and epochTime() > playDeadline:
            ## The platform kills an episode that outruns its timeout and
            ## keeps nothing at all, so give up hands rather than the whole
            ## result. Checked between hands: a part-played hand has no pot
            ## to settle.
            echo "cosino: episode deadline reached after ",
              state.match.handsPlayed, "/", config.hands,
              " hands; ending the match here"
            state.match.endMatchEarly()
            done = true
          if not done:
            state.match.nextHand()
            state.broadcastLocked()
        if done:
          break
        ## Let the verdict land before the next deal starts.
        if config.turnDelayMs > 0:
          sleep(config.turnDelayMs)

    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8"
    )

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "chrome.css",
      "text/css; charset=utf-8"
    )

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "cosino: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "cosino.player.v1",
        "slot": slot,
        "name": state.match.sim.seats[slot].name,
        "startingStack": state.config.startingStack,
        "smallBlind": state.config.smallBlind,
        "bigBlind": state.config.bigBlind,
        "hands": state.config.hands
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          if prompt.len > MaxPromptLen:
            prompt = prompt[0 ..< MaxPromptLen]
          let scripted = payload{"scripted"}.getBool(false)
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = scripted
          echo "cosino: slot ", slot, " delivered a prompt (",
            prompt.len, " chars", (if scripted: ", scripted" else: ""), ")"
      except CatchableError as error:
        echo "cosino: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  result.startingStack = payload["config"]{"startingStack"}.getInt(100)
  result.smallBlind = payload["config"]{"smallBlind"}.getInt(1)
  result.bigBlind = payload["config"]{"bigBlind"}.getInt(2)
  result.hands = payload["config"]{"hands"}.getInt(30)
  result.seed = payload["config"]{"seed"}.getInt(0)
  ## The replay carries the episode's fitted table; never re-fit it.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states,
  ## and serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("cosino.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "cosino: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(CosinoError, "tokens and players must align")
  state.config = config
  state.match = initMatch(config)
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[bool](config.players.len)
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "cosino: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
