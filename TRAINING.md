# Prompt diversity and training

Hosted configuration selects five training wordings: canonical, plain, numbered,
questions, and reordered. Mixed selection requires an explicit nonnegative
promptSeed and chooses seed modulo five. Heldout-briefing and heldout-reference
are evaluation-only. Selection stays fixed across hands, seats, and retries,
without changing the shuffle or policy randomness. Canonical preserves the
original prompt. Variants rewrite match accounting, public talk, and legal-action explanations.
Card rules, scoring values, action bounds, operator strategy, and private
observations remain fixed.

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

The source exporter requires clean committed source and exports complete matches:

```sh
nim c -d:release --path:src -o:/tmp/cosino-export tools/export_posttrain.nim
/tmp/cosino-export OUTPUT 10 1 kuhn mixed 4
```

The original train.jsonl, validation.jsonl, and manifest.json formats remain.
Mixed exports cycle five wordings separately within each split. This prevents
every-fifth-seed validation from excluding a training wording. The existing
house teacher supplies legal actions; imitation does not establish stronger play.
All tables, wordings, and seats sharing a scenario seed belong to one split.
Seeds divisible by five enter validation; other seeds enter training.
Held-out wording is excluded from training exports.

Compare base, canonical-trained, and mixed-trained checkpoints on matched seeds,
seats, opponents, and inference settings. Freeze training choices before evaluating
held-out wordings. Report completed and incomplete matches, legal actions,
normalizations, fallbacks, net chips, and native deadline/budget outcomes.

Run `tools/test_prompt_games.py BRIDGE` for complete matches, private-card
checks, normalized actions, and full-range wagers. Run
`tools/test_export_posttrain.py EXPORTER` for complete mixed exports.
These checks do not reproduce native inference timing or measure model robustness.

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
