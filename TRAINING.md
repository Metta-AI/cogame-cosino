# Metta post-training data

The native simulator and published `house` policy export supervised examples
for all six certified Cosino tables:

```sh
nimby sync nimby.lock
for variant in kuhn leduc holdem-hu holdem-6max headsup sixmax; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/cosino-${variant}" 10 1 "$variant"
done
```

Each run reads the table configuration from the Coworld manifest, adds the
per-seat tokens supplied by the hosted platform, and plays complete seeded
matches. Every row contains the acting seat's hosted system and user prompts
and a `house` move accepted by the game's reply parser. Parsed moves drive the
simulator. Whole matches stay in one split. The manifest records source
revision, table, hand count, chip results, and row counts. Existing output
directories are never overwritten.

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/cosino-kuhn \
  --output /tmp/cosino-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten matches per table yielded 6,951 examples. Every example fit the
Qwen2.5-0.5B-Instruct tokenizer in 4,096 tokens; the maximum was 1,060 tokens.
One CPU optimizer step per table with a local tiny model verifies the Metta
post-training path. These examples distill the scripted teacher; they do not
establish stronger league play.

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
