# Prompt diversity and training

Hosted configuration selects five training wordings: canonical, plain, numbered, questions, and reordered. Mixed
selection requires an explicit nonnegative promptSeed and chooses seed modulo five. Heldout-briefing and
heldout-reference are evaluation-only. Selection stays fixed across hands, seats, and retries, without changing the
shuffle or policy randomness. Canonical preserves the original prompt. Variants rewrite match accounting, public talk,
and legal-action explanations. Card rules, scoring values, action bounds, operator strategy, and private observations
remain fixed.

The bridge supports full text actions for all six published tables:

```sh
nim c -d:release --path:src -o:/tmp/cosino-bridge tools/train_bridge.nim
/tmp/cosino-bridge coworld_manifest_template.json holdem-hu text
```

Text actions retain the full legal wager range and table talk. The real parser, simulator, and fallback policy resolve
each submitted action. The response reports the action actually applied, including fixed-limit amount normalization.
Exact message hashes are private collection metadata. Training resets reject held-out wordings. The synchronous bridge
does not reproduce native inference latency, spacing, retries, or episode deadlines.

The source exporter requires clean committed source and exports complete matches:

```sh
nim c -d:release --path:src -o:/tmp/cosino-export tools/export_posttrain.nim
/tmp/cosino-export OUTPUT 10 1 kuhn mixed 4
```

The original train.jsonl, validation.jsonl, and manifest.json formats remain. Mixed exports cycle five wordings
separately within each split. This prevents every-fifth-seed validation from excluding a training wording. The existing
house teacher supplies legal actions; imitation does not establish stronger play. All tables, wordings, and seats
sharing a scenario seed belong to one split. Seeds divisible by five enter validation; other seeds enter training.
Held-out wording is excluded from training exports.

Compare base, canonical-trained, and mixed-trained checkpoints on matched seeds, seats, opponents, and inference
settings. Freeze training choices before evaluating held-out wordings. Report completed and incomplete matches, legal
actions, normalizations, fallbacks, net chips, and native deadline/budget outcomes.

Run `tools/test_prompt_games.py BRIDGE` for complete matches, private-card checks, normalized actions, and full-range
wagers. Run `tools/test_export_posttrain.py EXPORTER` for complete mixed exports. These checks do not reproduce native
inference timing or measure model robustness.

## Private native prompt-policy capture

The ordinary hosted game writes private decision JSONL when the runtime supplies `COGAME_SAVE_TRAJECTORY_URI`,
`COWORLD_EPISODE_ID`, `COWORLD_GAME_VERSION`, and `COWORLD_SOURCE_REVISION`. An immutable `COWORLD_GAME_IMAGE_DIGEST` is
retained when supplied. The destination must differ from both public result and replay destinations, including file-path
aliases and signed-query variants of one HTTP upload path. Without a private URI the added observations, family hashes,
request copies, raw byte/header evidence, and trajectory work are disabled.

Capture freezes the acting seat's existing redacted observation and actual prompt selection at dispatch. Model input
remains the native system/user messages, with the actual operator strategy. Opponents' unrevealed cards, future decks,
seed, policy names, and duplicate-pair metadata do not enter those inputs. Capture-only task identities and execution
metadata are never appended to a prompt or used to replace an authenticated request.

Every attempted native HTTP call retains its actual request JSON and wire body, safe protocol headers, received response
bytes/base64, response header map, call/provider IDs and usage when present, and native retry/error status. No
authorization headers or provider credentials are copied. Curly exposes parsed headers rather than original header
octets; that remains an explicit gap. Decoder evidence contains actual supplied request keys, including the native
`max_tokens`; absent sampling settings are not invented. Missing or negative provider usage remains null; real zero
counters remain zero.

The applied action comes from the new native `evAction` after `applyDecision`, and table talk comes from the actual new
`evSay`. This matters for fixed-limit bet/raise amounts, which the engine may replace. A selected model attempt must
have a complete joined successful HTTP response and unchanged supplied JSON fields, types, and values. Native fences and
omitted defaults can be eligible; case/whitespace changes, all-in aliases, call-to-check, ignored extra fields, changed
amounts, truncated talk, duplicate keys, nonfinite values, comments, trailing commas, invalid number/string spellings
and JSON nesting deeper than 32 are excluded. Raw evidence and the action actually played remain intact. Capture
rejection does not change native parsing or substitute a fallback. Scripted house/rock and external actions create no
synthetic model or teacher attempts.

Evidence is bounded: 64 KiB each for a request body, response body, and response text; 16 KiB of received header
names/values; 128 KiB per frozen observation; and 24 MiB per private episode. Exceeding a bound omits the whole affected
evidence field/decision, records a visible gap and failed capture, and never repairs a response or changes gameplay.
Publication errors remain visible in logs while normal public results and replay still finish.

Private JSON additionally requires valid Unicode scalar UTF-8 in every key, value, identity and terminal outcome. Lone
surrogates, malformed byte sequences and unsafe provider/header metadata cannot become selected targets. The
capture-only guard retains the complete original logical evidence JSON bytes as base64, records a visible error, and
emits no selected attempt or action for that row. Actual fallback status is preserved. Unsafe terminal outcomes are
likewise retained as original bytes with failed capture. Valid escaped accents and surrogate pairs remain eligible.
Native parsing, applied table talk, public replay and subsequent native requests are unchanged, even when the existing
native parser retains malformed bytes. Decoding the forensic field for inspection never repairs an artifact or creates a
training target.

Native capture has two private identities. The exact task hash retains effective rules, horizon, predeclared deal
schedule, seating and match structure. Its conservative split family hashes a fixed 500-index native root dealing stream
and resolved seating, independently of requested horizon, rules, wording, policy, deadlines and seed labels.
Horizon-only or same-stream rule changes therefore cannot create independent training/validation groups. Audit actual
deal-prefix and duplicate-pair overlap before assigning splits; differing seed labels or hashes alone do not establish
independent tasks. The legacy bridge and house-export seed partition above is not authenticated native capture.

The MIT decision writer is vendored from Bitworld `c336f54e10e9028d9cfbda540ee085ac7627fbb3`, with only its runtime
import changed. The public local proof uses an isolated loopback sentinel and real WebSocket players; sentinel output
never becomes a teacher:

```sh
nim c -d:release --path:src -o:/tmp/cosino src/cosino.nim
nim c -d:release --path:src -o:/tmp/cosino-player src/cosino_player.nim
python3 tools/test_native_capture.py --game /tmp/cosino \
  --player /tmp/cosino-player --variant kuhn --output /tmp/cosino-native-proof
nim c -d:release --path:src -o:/tmp/cosino-check tools/check_native_capture.nim
/tmp/cosino-check /tmp/cosino-native-proof/config.json \
  /tmp/cosino-native-proof/trajectory.jsonl /tmp/cosino-native-proof/replay.json \
  'native fixture only'
```

Run each published variant with and without `--no-capture`; compare request bodies, native events and outcomes.
Additional `--mode mixed`, `--mode retry`, and `--mode throttle-auth` cases exercise strict exclusions, native retry,
throttled/auth-disabled fallbacks, explicit evidence-size gaps and failed private publication. The checker independently
rebuilds every acting private view, prompt, applied event batch, full replay and outcome with the native simulator. The
additional `--mode strict-json` component uses an explicit 42-second fixture timeout, retains native deadline-truncated
artifacts within 30 seconds/4 MiB, and exits before shutdown grace; it is not a complete ordinary game. Reconstruct it
with the same checker plus `--allow-truncated`. These are protocol proofs, not genuine platform receipt admission,
strategic competence, teacher approval or learning evidence.

The maintained Unicode system regression exercises real HTTP replies, native parsing and application, persistent table
talk in later requests, parsed response headers and the private writer:

```sh
python3 tools/test_native_capture.py --game /tmp/cosino --player /tmp/cosino-player \
  --mode unicode --output /tmp/cosino-unicode-proof
/tmp/cosino-check /tmp/cosino-unicode-proof/config.json \
  /tmp/cosino-unicode-proof/trajectory.jsonl /tmp/cosino-unicode-proof/replay.json \
  'native fixture only' --allow-truncated
python3 tools/test_native_capture.py --game /tmp/cosino --player /tmp/cosino-player \
  --mode normal --ordinary-clock --output /tmp/cosino-ordinary-proof
```

The Unicode component keeps the published 250 ms pacing and 60-hand configuration, applies an explicit 42-second fixture
deadline, and retains the resulting deadline-truncated evidence within 30 seconds/8 MiB. It is not a complete match.
`--ordinary-clock` retains the manifest's clocks and horizon for a separate full regression (180 seconds/24 MiB). Both
paths sanitize the driver and child environments, use only a loopback sentinel, record request/response body bytes and
UUID fixture IDs, and retain wall/call/byte/disk and process CPU/RSS measurements throughout. Literal socket-frame and
original header octets remain unavailable; parsed headers are the received private evidence. Synthetic usage and fixture
IDs are not authenticated platform receipts. No provider inference or teacher collection occurs.

# Numeric reinforcement learning

Compile the persistent bridge and pass its binary, manifest, and variant to Metta's `recipes.external.coworld.train`
(native PufferLib) or `recipes.external.coworld_metta_rl.train` (Metta RL):

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/cosino-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/cosino-train-bridge
```

All six certified tables expose 200 numeric observations and seven fixed action slots. Illegal or duplicate choices are
masked. The action slots cover fold, check, call, minimum wager, half-pot wager, pot wager, and all-in. The native house
player supplies legal teacher actions, projected onto the nearest wager slot. The observation includes private cards
only for the acting seat. Opponent cards enter the structured view only after a public reveal. The bridge plays complete
matches with the native parser and simulator.

Episode IDs include the requested selection, resolved wording, and prompt seed. Matched exports remain distinct while
scenario seed families stay unchanged.
