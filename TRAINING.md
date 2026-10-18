# Prompt diversity and candidate training evidence

Hosted configuration selects five training wordings: canonical, plain, numbered,
questions, and reordered. Mixed selection requires an explicit nonnegative
promptSeed and chooses seed modulo five. Heldout-briefing and heldout-reference
are evaluation-only. Selection stays fixed across hands, seats, and retries,
without changing the shuffle or policy randomness. Canonical preserves the
original prompt. Variant rules, scoring instructions, action bounds, operator
strategy, and private observations remain unchanged.

The bridge supports full text actions for all six published tables:

```sh
nim c -d:release --path:src -o:/tmp/cosino-bridge tools/train_bridge.nim
/tmp/cosino-bridge coworld_manifest_template.json holdem-hu text
```

Text actions retain the full legal wager range and table talk. The real parser,
simulator, and fallback policy resolve each submitted action. The response reports
the action actually applied, including fixed-limit amount normalization. Exact
message hashes are private collection metadata. Training resets reject held-out
wordings. The synchronous bridge does not reproduce native inference latency,
spacing, retries, or episode deadlines.

The source exporter requires clean committed source and streams complete private
candidate trajectories:

```sh
nim c -d:release --path:src -o:/tmp/cosino-export tools/export_posttrain.nim
/tmp/cosino-export OUTPUT 10 1 kuhn mixed 4
```

Records preserve the house policy's original proposal, executed action, exact
prompts, source revision, and completed outcome. They contain no invented model
calls or log probabilities. The house policy is an existing scripted teacher;
its examples do not establish stronger model play.

Convert trajectories.jsonl with the shared Coworld importer and obtain independent
application review before training admission. All tables, wordings, and seats
sharing a scenario seed belong to one split. Held-out wording is excluded from
source training exports. These files are candidate evidence, not approved labels.

Compare base, canonical-trained, and mixed-trained checkpoints on matched seeds,
seats, opponents, and inference settings. Freeze training choices before evaluating
held-out wordings. Report completed and incomplete matches, legal actions,
normalizations, fallbacks, net chips, and native deadline/budget outcomes.

Native capture uses COSINO_HOST_TRACE_PATH for a fresh private host trace,
COSINO_SOURCE_REVISION for the checked source identity, and
COSINO_ATTEMPT_TRACE_DIR for actual request start/finish records. Requests
preserve exact retry prompts and transport model identity. Disabled or scripted
paths create no inference attempts. Host records identify the returned proposal,
engine-applied action, fallbacks, selected attempt, and terminal result.

Native diagnostics preserve the ordinary spacing, retries, throttling, decision
budget, and deadlines. A budget-limited match remains budget-limited in the
results. Scripted decisions and failed inference are not successful model calls.
Private prompts, operator strategies, and response evidence stay outside the
public replay. A parsed proposal can still be rejected by the engine; only host
execution evidence establishes which action ran.

# Numeric reinforcement learning

Compile the persistent bridge and pass its binary, manifest, and variant to
Metta's `recipes.external.coworld.train` (native PufferLib) or
`recipes.external.coworld_metta_rl.train` (Metta RL):

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/cosino-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/cosino-train-bridge
```

All six certified tables expose 200 numeric observations and seven fixed
action slots. Illegal or duplicate choices are masked. The action slots cover
fold, check, call, minimum wager, half-pot wager, pot wager, and all-in.
The native house player supplies legal teacher actions, projected onto the
nearest wager slot. The observation includes private cards only for the
acting seat. Opponent cards enter the structured view only after a public
reveal. The bridge plays complete matches with the native parser and simulator.
