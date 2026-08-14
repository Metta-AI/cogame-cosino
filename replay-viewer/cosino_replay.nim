## Cosino static replay viewer, wasm side.
##
## JS hands the raw replay bytes to cos_load_replay; this module parses
## them with the SAME sim code the game server runs, re-derives the
## per-event table states, and exposes the enriched payload (identical
## shape to the game's /replay websocket message) for the shared
## renderer.js to draw.

import
  std/json,
  cosino/sim

var
  payload: string
  lastError: string

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc cosLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "cos_load_replay", cdecl.} =
  try:
    lastError = ""
    let replay = parseJson(bytesFromPointer(data, int(length)))
    var config = defaultGameConfig()
    config.startingStack = replay["config"]{"startingStack"}.getInt(100)
    config.smallBlind = replay["config"]{"smallBlind"}.getInt(1)
    config.bigBlind = replay["config"]{"bigBlind"}.getInt(2)
    config.hands = replay["config"]{"hands"}.getInt(30)
    config.seed = replay["config"]{"seed"}.getInt(0)
    config.sampled = true
    for name in replay["names"]:
      config.players.add(PlayerConfig(name: name.getStr()))
    var events: seq[GameEvent]
    for node in replay["events"]:
      events.add(eventFromJson(node))
    var states = newJArray()
    for frame in replayMatch(config, events):
      states.add(frame.frameStateJson())
    payload = $ %*{
      "type": "replay",
      "protocol": replay{"protocol"}.getStr("cosino.replay.v1"),
      "names": replay["names"],
      "policyNames": replay{"policyNames"},
      "config": replay["config"],
      "events": replay["events"],
      "results": replay{"results"},
      "states": states
    }
    return 1
  except CatchableError as error:
    lastError = error.msg
    return 0

proc cosPayloadPointer(): ptr uint8 {.exportc: "cos_payload_ptr", cdecl.} =
  if payload.len == 0:
    nil
  else:
    cast[ptr uint8](payload[0].addr)

proc cosPayloadLength(): cint {.exportc: "cos_payload_len", cdecl.} =
  cint(payload.len)

proc cosErrorPointer(): ptr uint8 {.exportc: "cos_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc cosErrorLength(): cint {.exportc: "cos_error_len", cdecl.} =
  cint(lastError.len)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  ## Nim's generated main would run module-global destructors on return,
  ## freeing `payload` and friends while JS keeps calling into the module.
  ## Exiting with a live runtime skips the destructor epilogue so globals
  ## stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
