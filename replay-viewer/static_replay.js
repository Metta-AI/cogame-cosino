// Cosino static replay shell: fetches the replay named by ?replay=<url>,
// hands the bytes to the wasm module (which re-derives the state timeline
// with the same Nim sim the game server runs), then drives the shared
// renderer with the resulting payload.
(function () {
  "use strict";

  function fail(message) {
    var loading = document.getElementById("loading");
    if (loading) loading.textContent = "Replay failed: " + message;
    document.documentElement.setAttribute("data-replay-error", message);
  }

  function readString(module, ptr, len) {
    if (!ptr || !len) return "";
    return new TextDecoder().decode(
      module.HEAPU8.subarray(ptr, ptr + len)
    );
  }

  function start(module, bytes) {
    var ptr = module._malloc(bytes.length);
    module.HEAPU8.set(bytes, ptr);
    var ok = module._cos_load_replay(ptr, bytes.length);
    module._free(ptr);
    if (!ok) {
      fail(readString(module, module._cos_error_ptr(),
        module._cos_error_len()) || "wasm rejected the replay");
      return;
    }
    var payload = JSON.parse(
      readString(module, module._cos_payload_ptr(),
        module._cos_payload_len())
    );
    var loading = document.getElementById("loading");
    if (loading) loading.style.display = "none";
    CosinoRenderer.attachReplay({
      canvas: document.getElementById("table"),
      feed: document.getElementById("feed"),
      scrub: document.getElementById("scrub"),
      playButton: document.getElementById("play"),
      label: document.getElementById("pos"),
      clock: document.getElementById("clock"),
      scorebug: document.getElementById("scorebug"),
      endscreen: document.getElementById("endscreen"),
      assetBase: "./assets",
      payload: payload
    });
  }

  window.addEventListener("load", function () {
    var replayUrl = new URLSearchParams(location.search).get("replay");
    if (!replayUrl) {
      fail("missing required ?replay= URL");
      return;
    }
    Promise.all([
      fetch(replayUrl).then(function (response) {
        if (!response.ok) throw new Error("replay fetch " + response.status);
        return response.arrayBuffer();
      }),
      CosinoReplayModule()
    ]).then(function (results) {
      start(results[1], new Uint8Array(results[0]));
    }).catch(function (error) {
      fail(String(error && error.message || error));
    });
  });
})();
