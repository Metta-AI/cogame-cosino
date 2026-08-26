## Cosino game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - shared table renderer
##   GET /client/chrome.css          - shared chrome
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol (prompt delivery)
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol (cosino.player.v1), all JSON text frames:
##   game -> player: {"type":"welcome","protocol":"cosino.player.v1",...}
##                   {"type":"state",...} after every event batch
##                   {"type":"final","done":true,"scores":[...],...}
##   player -> game: {"type":"prompt","prompt":"...","scripted":bool,
##                    "baseline":"house"|"rock"}   (prompt max 4000 runes)

import
  std/[json, locks, os, sets, strutils, tables, times],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  ReplayVersion = 1
  ## Bounded post-artifact grace: the certification runner pings /healthz and
  ## /global AFTER the player pods start, and a short episode has already
  ## written its artifacts by then (lantern 0.1.3 -> 0.1.4). The runner waits
  ## on process exit anyway.
  ShutdownGraceSeconds = 20

type
  GameState = object
    config: GameConfig
    match: Match
    prompts: seq[string]
    scripted: seq[bool]
    baselines: seq[Baseline]
    fallbacks: seq[int]
    forcedFolds: seq[int]
    decisions: seq[int]
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
  ## Seats play under anonymous table aliases; the policy names ride alongside
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
  result["config"] = replayConfigJson(gs.config)
  result["hands"] = %gs.config.hands
  result["handsPlayed"] = %gs.match.handsPlayed
  result["variant"] = %($gs.config.variant)
  result["startingStack"] = %gs.config.startingStack
  result["ante"] = %gs.config.ante
  result["smallBlind"] = %gs.config.smallBlind
  result["bigBlind"] = %gs.config.bigBlind
  result["started"] = %gs.started
  result["done"] = %gs.match.done
  result["connected"] = connected

proc redactCards(snapshot: JsonNode, slot: int) =
  ## Hole cards are secret: a player sees only its own, plus whatever the
  ## showdown made public. The calibration and audit tails are spectator-only
  ## diagnostics and are stripped as well.
  for index, seat in snapshot["seats"].getElems():
    if index != slot and not seat{"revealed"}.getBool(false):
      seat["cards"] = newJArray()
  var visible = newJArray()
  for event in snapshot["events"]:
    let kind = event{"kind"}.getStr()
    if kind == "deal" and event{"seat"}.getInt() != slot:
      continue
    if kind in ["calib", "audit"]:
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
    ## Players never learn who is behind a seat — that is the whole point of
    ## the aliases — so the policy-name map is spectator-only.
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
      raise newException(IOError, "artifact POST failed: " & $response.code)
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
    "config": replayConfigJson(gs.config),
    "events": events,
    "results": results
  }

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    state.match.finishMatch()
    results = state.match.resultsJson(state.fallbacks, state.forcedFolds,
      state.decisions)
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection. Results carry POLICY
    ## names for the platform; the players get the table aliases.
    var aliasNames = newJArray()
    for seat in state.match.sim.seats:
      aliasNames.add(%seat.name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "win": results["win"],
      "names": aliasNames,
      "net": results["net"],
      "handsPlayed": results["handsPlayed"],
      "reason": results["reason"]
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
  echo "cosino: artifacts written; holding the routes open for ",
    ShutdownGraceSeconds, "s"
  sleep(ShutdownGraceSeconds * 1000)
  echo "cosino: episode complete, shutting down"
  quit(0)

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

    ## The game container is NOT given COWORLD_TIMEOUT_SECONDS (only the
    ## worker sidecar is), so assume the platform's 1200 s when it is absent
    ## and play well inside it. An episode that overruns is discarded whole.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    let timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout)
        except ValueError: DefaultEpisodeTimeoutSeconds
      else: DefaultEpisodeTimeoutSeconds
    let softDeadline = gameStart + timeoutSeconds * PlayBudgetFraction
    let hardDeadline = gameStart + timeoutSeconds * HardDeadlineFraction
    echo "cosino: episode timeout ", timeoutSeconds.int, "s; soft stop at ",
      (timeoutSeconds * PlayBudgetFraction).int, "s, hard stop at ",
      (timeoutSeconds * HardDeadlineFraction).int, "s"

    var spent = 0

    proc matchHeader(): string =
      "Hand " & $(state.match.sim.hand + 1) & " of " &
        $state.config.hands & " in the match (" & $state.config.variant & ")."

    while true:
      var simCopy: Sim
      var seat: int
      var seatPrompt: string
      var seatScripted: bool
      var seatBaseline: Baseline
      var header: string
      var stopNow = false
      withLock stateLock:
        if state.match.done:
          stopNow = true
        elif epochTime() > hardDeadline:
          ## Hard guard, checked before EVERY decision: abandon the live hand,
          ## refund every chip in it (so the nets still sum to zero), stop.
          echo "cosino: hard deadline reached mid-hand; voiding hand ",
            state.match.sim.hand + 1
          state.match.voidLiveHand()
          state.match.endMatchEarly(erDeadline)
          state.broadcastLocked()
          stopNow = true
        else:
          simCopy = state.match.sim
          seat = state.match.sim.actingSeat
          if seat < 0:
            echo "cosino: no acting seat on a live hand; ending match"
            state.match.endMatchEarly(erComplete)
            stopNow = true
          else:
            seatPrompt = state.prompts[seat]
            seatScripted = state.scripted[seat]
            seatBaseline = state.baselines[seat]
            header = matchHeader()
      if stopNow:
        break

      ## The slow part (Claude) runs outside the lock on a snapshot; only this
      ## thread mutates the match, so the snapshot cannot go stale.
      let decision = client.decide(simCopy, seat, seatPrompt,
        scripted = seatScripted, baseline = seatBaseline, header = header)
      inc spent

      var handEnded = false
      withLock stateLock:
        inc state.decisions[seat]
        ## Degrade twice, never hang: illegal -> baseline -> fold.
        let outcome = client.applyDecision(state.match.sim, seat, decision,
          seatBaseline)
        state.fallbacks[seat] += outcome.fallbacks
        state.forcedFolds[seat] += outcome.forcedFolds
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
          ## Soft guards are checked at a PAIR boundary so no duplicate pair
          ## is left half-played.
          let atBoundary = not config.duplicate or
            (state.match.handsPlayed mod 2 == 0)
          if not done and atBoundary and spent >= EpisodeDecisionBudget:
            echo "cosino: decision budget spent after ",
              state.match.handsPlayed, " hands; settling here"
            state.match.endMatchEarly(erBudget)
            done = true
          if not done and atBoundary and epochTime() > softDeadline:
            echo "cosino: soft deadline reached after ",
              state.match.handsPlayed, "/", config.hands,
              " hands; settling here"
            state.match.endMatchEarly(erDeadline)
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
    serveFile(request, clientDir() / "chrome.css", "text/css; charset=utf-8")

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
        "variant": $state.config.variant,
        "startingStack": state.config.startingStack,
        "ante": state.config.ante,
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
      ## mummy hands Ping frames to the application instead of answering them
      ## itself; the platform's certifier pings /global to check the game is
      ## alive, so an unanswered ping fails certification.
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
          ## Rune-truncated, never byte-truncated: a byte cut mid-rune renders
          ## in a browser and then fails a strict UTF-8 parser downstream.
          let prompt = truncateRunes(payload{"prompt"}.getStr(), MaxPromptLen)
          let scripted = payload{"scripted"}.getBool(false)
          let baseline = parseBaseline(payload{"baseline"}.getStr("house"))
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = scripted
            state.baselines[slot] = baseline
          echo "cosino: slot ", slot, " delivered a prompt (", prompt.len,
            " chars", (if scripted: ", scripted " & $baseline else: ""), ")"
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

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states, and
  ## serve the viewer until the platform tears the container down.
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
  ## initMatch settles the seed-derived seating; keep the served config in
  ## step so the replay carries the order the hands were actually dealt with.
  state.config = state.match.config
  let n = config.players.len
  state.prompts = newSeq[string](n)
  state.scripted = newSeq[bool](n)
  state.baselines = newSeq[Baseline](n)
  state.fallbacks = newSeq[int](n)
  state.forcedFolds = newSeq[int](n)
  state.decisions = newSeq[int](n)
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "cosino: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
