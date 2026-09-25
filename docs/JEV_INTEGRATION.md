# Jev as a Cosino player

`cosino.player.v2` lets a player register `{"type":"register","control":"external"}`.
The game sends that seat a redacted observation with its private cards, public
events, scoring rules, and `actionSpace`. Fixed-limit bet and raise entries
carry one exact amount; no-limit entries carry the complete legal range. An
external player replies with `{"type":"action","id":N,"kind":"call"}` or a
bet or raise with `amount`. The game checks the decision ID and action, then
records the outcome in results and replay. A missing or invalid decision uses
the existing house fallback.

`PLAYER_JEV=1` runs Jev in the player container. The player samples candidate
amounts from each legal range and asks SystemOne to rank the candidates. It
accepts a direct `TYPESAFE_API_KEY` or the hosted inference sidecar. The game
does not receive either credential or a Jev prompt. Prompt control and the
house and rock scripted policies remain available.

## Local evidence

Built with `coworld[auth]==0.1.43` into `dist-jev/`, using
`compose.jev-local.yaml` and version `0.1.99`. Normal Coworld certification
passed all 10 checks. The manifest keeps its prompt and house certification
players; the separate mixed player smoke exercises Jev:

```bash
python3 tools/ci/smoke_jev.py /tmp/cosino-jev-smoke
```

The mock SystemOne run accepted 21 Jev actions across Kuhn, Leduc, Hold'em
heads-up, Hold'em six-max, heads-up chip race, and six-max chip race. Each
episode produced results and a replay; Jev had zero fallbacks. The smoke
checks private-card and future-deck redaction, candidate bounds, direct and
sidecar headers, and replay action amounts. Linux `tests/test_sim.nim` passed
in debug and release, including exact replay fixture regeneration. The other
native suites passed in debug and release locally.

These are mock inference results. No live TypeSafe/OpenRouter credential was
available for local model-quality or cost measurements. No hosted game or
policy release was performed.
