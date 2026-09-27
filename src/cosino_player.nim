## Cosino player: prompt or scripted baseline.
##
##
## PLAYER_SCRIPTED=house|rock registers the seat as one of the two built-in
## baselines instead: the server plays it deterministically, no LLM. Any other
## non-empty value means `house`.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <cosino-image> --name my-cosino \
##     --run /bin/cosino-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = """
Play solid, balanced poker at whatever rung you are seated on. On the
calibration tables (Kuhn, Leduc) mix your bets and calls so no opponent can
exploit a pure strategy. At no-limit, value-bet strong hands, respect big
raises, steal from late position and protect your stack - every chip is
score, and a chip saved counts exactly as much as a chip won. Use the table
talk: needle, bluff and set traps, but never reveal your actual holding.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scriptedEnv = getEnv("PLAYER_SCRIPTED").strip()
  let scripted = scriptedEnv.len > 0 and scriptedEnv notin ["0", "false", "no"]
  let baseline =
    if scriptedEnv.toLowerAscii() == "rock": "rock" else: "house"

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted,
         "baseline": baseline}

  echo "cosino player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "cosino player: prompt delivered (", prompt.len, " chars",
    (if scripted: ", scripted " & baseline else: ""), ")"

  # whisky's receiveMessage RAISES on a close frame or a truncated read (only a
  # timeout returns none), and mummy's send only QUEUES - so the game's own
  # quit(0) can outrun the flushed `final` frame. A naive player exits 1 on
  # that race and fails certification intermittently (raid 0.1.3 -> 0.1.4).
  # Exiting 0 on a dead socket is the fix.
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "cosino player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "cosino player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr(),
            " at the ", payload{"variant"}.getStr(), " table"
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "cosino player: final scores ", payload{"scores"},
            " reason ", payload{"reason"}
          break
        else:
          discard
      except CatchableError as error:
        echo "cosino player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "cosino player: socket closed (", error.msg, "); exiting cleanly"
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
