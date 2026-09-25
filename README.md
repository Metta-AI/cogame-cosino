# cogame-cosino — Cosino

Poker for the Softmax Coworld platform: the imperfect-information **ladder**
— **Kuhn → Leduc → no-limit Hold'em heads-up → no-limit Hold'em six-max** —
plus the classic **chip-race tables**, one binary, one protocol, six manifest
variants. (The ladder was born as `cogame-poker`, itself forked from this
repo's original chip-race game; the two are merged here as variants of one
game.)

Players can register a prompt, a scripted baseline, or an external action
policy over `cosino.player.v2`. External policies receive their private cards,
the public table, and complete legal action bounds. They return a kind,
amount when needed, and optional table talk. The game validates actions and
owns rules, results, and replay. `PLAYER_JEV=1` ranks candidate actions in the
player container. Prompt players retain the original game-hosted Claude path.

Watch it: <https://softmax.com/cosino>

---

## The game

Six tables of the same zero-sum game.

| variant | seats | rules | hands |
| --- | --- | --- | --- |
| `kuhn` | 2 | OpenSpiel `kuhn_poker`: 3 cards, one round, one wager, 12 information sets | 60 (30 pairs) |
| `leduc` | 2 | OpenSpiel `leduc_poker`: 6 cards, two rounds, one board card, two wagers per round | 36 (18 pairs) |
| `holdem-hu` | 2 | full no-limit Texas Hold'em, blinds 1/2 | 30 (15 pairs) |
| `holdem-6max` | 6 | the same, six-handed, seating randomised from the seed | 14 (7 pairs) |
| `headsup` | 2 | the chip race, heads-up: stacks carry, busts are final | up to 20 |
| `sixmax` | 6 | the chip race, six-handed: the button walks to the next funded seat | up to 16 |

What is the same at every LADDER rung:

- **Hands, not a chip race.** Every hand starts with every seat on
  `startingStack`. No busts, no rebuys, no seats sitting out. A seat that ends
  a hand with nothing gets a cosmetic `stackOff` event and is full again next
  hand.
- **Duplicate decks.** Hands are played in pairs. Hands `2k` and `2k+1` are
  dealt from the *same* shuffled deck; in the mirror the whole table rotates by
  half a table, so each seat gets the cards *and* the position its counterpart
  had. Deal luck cancels inside the pair. The mirror is invisible to the seats.
- **Anonymous aliases.** Seats play as Sprocket, Gizmo, Ratchet… No policy name
  ever enters a prompt. The spectator layer maps them back.
- **Table talk.** Every decision may carry one public line (`say`, ≤ 120 runes).

### The chip-race tables

`headsup` and `sixmax` (`chipRace: true`) are the original Cosino cash game:
the same no-limit Hold'em rules, but stacks **carry** between hands, the
button walks clockwise to the next funded seat, and a cog that loses its last
chip is **out for good** (a `bust` event — no rebuys). The match ends at the
hand limit or when one cog holds every chip. There are no duplicate pairs —
variance is part of the table.

### Score

```
scores[i] = 1/n + net[i] / (n * startingStack * handsScored)   # ladder
scores[i] = stack[i] / (n * startingStack)                     # chip race
win[i]    = (net[i] == max(net))
```

`Σ net == 0` exactly, so `Σ scores == 1`, the range is exactly `[0, 1]` with no
clamping, and a seat that breaks even scores exactly `1/n`. The chip race is
the `H = 1` degenerate case of the same formula — a plain chip share — so the
score is unit-free and one Elo ladder ranks all six tables.

### Diagnostics (never inputs to the ranking)

- **Exploitability**, exact, for `kuhn` and `leduc`. Every decision is tagged
  with its information set; unvisited sets are filled (`nash` at α = 1/6 for
  Kuhn, `uniform` for Leduc) and the coverage is reported.
  `src/cosino/solve.nim` enumerates the whole game tree and computes the exact
  best-response value by backward induction — no sampling, no CFR. `null` at
  Hold'em, where no exact best response exists.
- **Collusion audit** at every table with three or more seats: per-pair
  equity surrender against the field,
  flagging `soft-play` (mutual) and `dump-a-to-b` (directed). A pure function
  of the event log plus the seed, so the browser re-derives it from the replay
  bytes. See `docs` page `audit.md` in the manifest.

---

## Fielding a policy

```bash
coworld upload-policy coworld-cosino:latest \
  --name my-cosino \
  --run /bin/cosino-player \
  --secret-env PLAYER_PROMPT="Play balanced poker. Mix your bluffs..."
```

Or field one of the two built-in baselines from the same image:

```bash
coworld upload-policy coworld-cosino:latest --name cosino-house \
  --run /bin/cosino-player --secret-env PLAYER_SCRIPTED=house
```

Set `PLAYER_JEV=1` to field the external Jev player. Its TypeSafe credential
or hosted inference sidecar belongs to the player policy. `PLAYER_PROMPT`
provides optional strategy guidance. Jev samples bet and raise candidates
from the game's complete legal amount range; the game accepts any legal
amount from an external policy.

- **`house`** — the exact α = 1/6 Kuhn equilibrium (measured exploitability 0),
  a Leduc rule table, and a Chen-formula no-limit bot. It is also the fallback
  whenever a model decision fails.
- **`rock`** — deterministic, never bluffs, deliberately exploitable.

The repo's own set is in `tools/ci/policies.json`.

---

## Layout

```
src/cosino.nim              entrypoint: live episode server or replay server
src/cosino/cards.nim        0-51 encoding, hand evaluation, Kuhn/Leduc decks
src/cosino/types.nim        config, events, seats, truncateRunes
src/cosino/sim.nim          the rules: hands, duplicate pairs, scoring, replay
src/cosino/solve.nim        exact best response and exploitability
src/cosino/audit.nim        equity, surrender, bias, collusion flags
src/cosino/llm.nim          decisions, prompts, the two scripted baselines
src/cosino/server.nim       the Coworld game contract
src/cosino_player.nim       prompt, scripted, and Jev player entrypoint
src/cosino/jev_policy.nim  Jev request and action candidate ranking
client/                    chrome.css + renderer.js + the three live pages
replay-viewer/             the static wasm bundle (config.nims, cosino_replay.nim,
                           static_replay.js, index.html)
tools/build_replay_viewer.sh   the `coworld build` hook (mode 100755)
tools/ci/                  docker_smoke.sh, viewer_smoke.mjs, policies.json
                           smoke_jev.py (mixed external action path)
tests/                     six suites, run twice (debug and -d:release) in CI
```

Replays are a **static file plus a browser wasm viewer** — never a pod. The
same Nim sim module drives the server, the tests and the wasm module, and the
replay bytes carry everything the viewer needs (names, config, events, results
and the seed), so nothing is fetched but the `.replay` file itself.

---

## Building

The Docker image is one image with two entrypoints, `/bin/cosino` (default) and
`/bin/cosino-player`:

```bash
docker build --platform=linux/amd64 -t coworld-cosino:latest .
```

Locally, `nim.cfg` is generated per machine from the synced package tree
(the committed one would pin somebody else's paths), so:

```bash
nimby use 2.2.4
nimby --global sync nimby.lock
rm -f nim.cfg
for pkg in "$HOME"/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg
for t in tests/*.nim; do nim r --hints:off --path:src "$t"; done
```

## CI

`.github/workflows/ci.yml` is the only harness that matters. Three jobs:

- **`test`** — static gates (exec bits, the `CosinoReplayModule` pair, no
  game-block name shadowing a chrome alias, every scrubber beat kind has CSS)
  then every `tests/*.nim` twice, debug and `-d:release`.
- **`docker-smoke`** — builds the production image and runs one real episode of
  the certification fixture in raw docker with **no** `ANTHROPIC_API_KEY`, so
  both seats play scripted. It then seats mock Jev against the house baseline
  across all six tables, checking private observations, action acceptance,
  results, and replay. Uploads the normal replay as `smoke-replay`.
- **`wasm-viewer`** — builds the static bundle and **executes** it in headless
  Chromium three times: against the smoke replay, the committed six-max
  fixture `tools/ci/fixtures/sixmax_audit.replay` (two flagged pairs and a
  full-120-rune `say` on every seat) and the committed chip-race fixture
  `tools/ci/fixtures/chiprace_bust.replay` (three busts, the walking button).
  Both fixtures are regenerated and diffed by `tests/test_sim.nim`. All with
  `--soak 12 --strict-text-bounds`.

`.github/workflows/coworld-release.yml` (dispatch) runs
build → certify → upload policies → upload coworld → put secret, in that order,
and uploads `release-result.json`. `.github/workflows/coworld-submit.yml`
(dispatch) submits a policy to a league as a given player.

## Licence

MIT. Sprites and font under `data/` come from `coworld-ctf`; see
`data/FONT_LICENSE.txt`.
