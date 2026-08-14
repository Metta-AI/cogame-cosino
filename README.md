# Cosino

No-limit Texas Hold'em for the Softmax Coworld platform, on the
[cogame-parley](https://github.com/Metta-AI/cogame-parley) technology
stack. 2–6 cogs at a felt table, fixed buy-in (default 100 chips), 1/2
blinds, full no-limit betting with all-ins, side pots, and split pots. The
final **chip share is the score**; the biggest stack takes the table.

**The game is LLM-driven and a policy is just a prompt.** Every turn the
game server sends the acting seat's policy prompt, its private hole cards,
and the public table state to Claude, which answers with what the cog says
and does with its chips. Player containers exist only to deliver their
prompt over the websocket. A built-in **scripted baseline** (Chen-formula
preflop, made-hand strength and pot odds postflop) plays any seat that
registers as scripted — and every seat when no LLM credentials are
available, so episodes (and offline certification) always complete.

Seats play under **anonymous cog names** (Sprocket, Gizmo, …): policy
display names never reach the agents' prompts, so nobody can meta-game
"that seat is the champion". The spectator and replay viewers map the
aliases back to policy names; results are reported under policy names.

## Layout

- `src/cosino.nim` — entrypoint (Coworld runtime contract, live vs replay mode)
- `src/cosino/cards.nim` — cards and the 7-card hand evaluator
- `src/cosino/sim.nim` — pure rules: betting engine, side pots, match loop;
  shared by server, tests, and the wasm viewer
- `src/cosino/llm.nim` — Claude client + the scripted baseline bot
- `src/cosino/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/cosino_player.nim` — the prompt-delivery player (`PLAYER_PROMPT` /
  `PLAYER_SCRIPTED` env)
- `client/` — shared canvas renderer + global/player/replay pages
- `replay-viewer/` — static wasm replay viewer (`?replay=<url>`)
- `tools/build_replay_viewer.sh` — Coworld replay-viewer build hook
- `data/` — cog sprites and art, borrowed from
  [coworld-ctf](https://github.com/Metta-AI/coworld-ctf) (MIT)

## Local loop

```bash
export PATH="$HOME/.nimby/nim/bin:$PATH"
nimby --global sync nimby.lock                 # fetch pinned packages
# Generate nim.cfg from your nimby package tree (not committed - the
# paths are machine-specific):
rm -f nim.cfg
for pkg in ~/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg;
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

nim r --path:src tests/test_sim.nim            # rules tests
nim r --path:src tests/test_bot.nim            # scripted-baseline tests
nim c -d:release -o:bin/cosino src/cosino.nim
nim c -d:release -o:bin/cosino-player src/cosino_player.nim
# See tmp/config.json for a table fixture; run with COGAME_* env + players.
# Export ANTHROPIC_API_KEY for real Claude play; omit for the scripted
# baseline.
```

Coworld packaging (from a metta checkout):

```bash
uv run coworld build --project <this dir> --version 0.1.x
uv run coworld certify <this dir>/dist/coworld_manifest.json
uv run coworld upload-coworld <this dir>/dist/coworld_manifest.json
uv run coworld secret put cosino anthropic_api_key <keyfile>   # hosted Claude
```

## Fielding a policy

```bash
uv run coworld upload-policy <cosino image> --name my-cosino \
  --run /bin/cosino-player \
  --secret-env PLAYER_PROMPT="Your poker strategy here."
```

Or field the scripted shark: same image, `--env PLAYER_SCRIPTED=1`.
