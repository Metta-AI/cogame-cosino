## Cosino static replay viewer, wasm side.
##
## JS hands the raw replay bytes to pkr_load_replay; this module parses them
## with the SAME sim code the game server runs, re-derives the per-event table
## states, and exposes the enriched payload (identical shape to the game's
## /replay websocket message) for the shared renderer.js to draw.

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

proc pkrLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "pkr_load_replay", cdecl.} =
  try:
    lastError = ""
    let replay = parseJson(bytesFromPointer(data, int(length)))
    let config = configFromReplay(replay)
    var events: seq[GameEvent]
    for node in replay["events"]:
      events.add(eventFromJson(node))
    var results = replay{"results"}
    if results.isNil or results.kind != JObject:
      results = newJNull()
    elif not results.hasKey("audit"):
      ## The audit is a PURE function of the events plus the seed, so a replay
      ## that predates the tail can still be audited in the browser with the
      ## identical code the server ran.
      results["audit"] = auditFromEvents(config, events)
    payload = $ %*{
      "type": "replay",
      "protocol": replay{"protocol"}.getStr("cosino.replay.v1"),
      "names": replay["names"],
      "policyNames": replay{"policyNames"},
      "config": replay["config"],
      "events": replay["events"],
      "results": results,
      "states": statesFromEvents(config, events)
    }
    return 1
  except CatchableError as error:
    lastError = error.msg
    return 0

proc pkrPayloadPointer(): ptr uint8 {.exportc: "pkr_payload_ptr", cdecl.} =
  if payload.len == 0:
    nil
  else:
    cast[ptr uint8](payload[0].addr)

proc pkrPayloadLength(): cint {.exportc: "pkr_payload_len", cdecl.} =
  cint(payload.len)

proc pkrErrorPointer(): ptr uint8 {.exportc: "pkr_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc pkrErrorLength(): cint {.exportc: "pkr_error_len", cdecl.} =
  cint(lastError.len)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  ## Nim's generated main would run module-global destructors on return,
  ## freeing `payload` and friends while JS keeps calling into the module.
  ## Exiting with a live runtime skips the destructor epilogue so globals stay
  ## valid for the life of the page.
  emscriptenExitWithLiveRuntime()
