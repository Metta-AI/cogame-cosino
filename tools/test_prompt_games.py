"""Complete all six published tables with matched wordings and original policies."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRIDGE = Path(sys.argv[1]).resolve()
VARIANTS = ("kuhn", "leduc", "holdem-hu", "holdem-6max", "headsup", "sixmax")
WORDINGS = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
)


def play(variant, seed, wording, prompt_seed, normalize=False, full_range=False):
    with subprocess.Popen(
        [str(BRIDGE), str(ROOT / "coworld_manifest_template.json"), variant, "text"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as process:
        assert process.stdin is not None and process.stdout is not None

        def request(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        players = 6 if variant in ("holdem-6max", "sixmax") else 2
        observation = request(
            {
                "kind": "reset",
                "players": players,
                "seed": seed,
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "test" if wording.startswith("heldout-") else "train",
            }
        )
        trace, systems = [], {}
        nonprojected = 0
        while observation["kind"] == "decision":
            view = observation["semantic_view"].copy()
            metadata = view.pop("prompt_template")
            messages = observation["messages"]
            expected = WORDINGS[prompt_seed] if wording == "mixed" else wording
            assert (metadata["bank"], metadata["variant"]) == (
                "cosino-rules-v2",
                expected,
            )
            for message in messages:
                assert (
                    metadata[message["role"] + "_sha256"].lower()
                    == hashlib.sha256(message["content"].encode()).hexdigest()
                )
            system = messages[0]["content"]
            assert systems.setdefault(observation["seat"], system) == system
            assert all(
                not seat["revealed_cards"]
                for seat in view["seats"]
                if not seat["revealed"]
            )
            proposal = json.loads(request({"kind": "teacher"})["response"])
            if full_range:
                choices = request({"kind": "encode"})["actions"]
                for legal in view["legal_actions"]:
                    if legal["kind"] not in ("bet", "raise"):
                        continue
                    projected = {
                        choice["amount"]
                        for choice in choices
                        if choice is not None and "amount" in choice
                    }
                    amount = next(
                        (
                            value
                            for value in range(
                                legal["min"], min(legal["max"], legal["min"] + 8) + 1
                            )
                            if value not in projected
                        ),
                        None,
                    )
                    if amount is not None:
                        proposal.update(action=legal["kind"], amount=amount)
                        nonprojected += 1
            if normalize:
                proposal["say"] = "雪" * 140
                proposal["action"] = proposal["action"].upper()
                if variant in ("kuhn", "leduc") and proposal["action"] in (
                    "BET",
                    "RAISE",
                ):
                    proposal["amount"] = 999999
            accepted = request(
                {
                    "kind": "step",
                    "decision_id": observation["decision_id"],
                    "response": json.dumps(proposal),
                }
            )
            assert accepted["kind"] == "accepted"
            if normalize:
                assert accepted["action"]["say"] == "雪" * 119 + "…"
                assert accepted["action"]["action"] == proposal["action"].lower()
                if variant in ("kuhn", "leduc") and "amount" in accepted["action"]:
                    assert accepted["action"]["amount"] < 999999
            else:
                assert accepted["action"] == proposal
            trace.append((view, messages, accepted["action"]))
            observation = accepted["observation"]
            assert len(trace) < 10000
        process.stdin.close()
        assert process.wait(timeout=30) == 0
        assert observation["kind"] == "terminal" and trace
        assert len(observation["scores"]) == players
        assert all(0 <= value <= 1 for value in observation["scores"].values())
        assert abs(sum(observation["scores"].values()) - 1) < 1e-9
        if full_range:
            assert nonprojected > 0
        return trace, observation["scores"]


for variant in VARIANTS:
    for heldout in WORDINGS[5:]:
        rejected = subprocess.run(
            [
                str(BRIDGE),
                str(ROOT / "coworld_manifest_template.json"),
                variant,
                "text",
            ],
            input=json.dumps(
                {
                    "kind": "reset",
                    "players": 6 if variant in ("holdem-6max", "sixmax") else 2,
                    "seed": "17",
                    "promptVariant": heldout,
                    "split": "train",
                }
            )
            + "\n",
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert rejected.returncode != 0 and "evaluation-only" in rejected.stderr
    canonical_first = None
    for seed in ("17",):
        canonical = None
        introductions = set()
        selected_systems = {}
        for wording, prompt_seed in [*((name, 0) for name in WORDINGS), ("mixed", 4)]:
            trace, scores = play(variant, seed, wording, prompt_seed)
            selected = WORDINGS[prompt_seed] if wording == "mixed" else wording
            rendered = trace[0][1][0]["content"]
            assert selected_systems.setdefault(selected, rendered) == rendered
            introductions.add(rendered)
            stripped = [(view, messages[1], action) for view, messages, action in trace]
            if canonical is None:
                canonical = stripped, scores
                if seed == "17":
                    canonical_first = trace, scores
            else:
                assert (stripped, scores) == canonical
        assert len(introductions) == 7
        print(variant, seed, "8 complete matched games PASS", flush=True)
    normalized, scores = play(variant, "17", "canonical", 0, normalize=True)
    assert canonical_first is not None and scores == canonical_first[1]
    print(variant, "complete normalized-action game PASS", flush=True)

play("holdem-hu", "17", "canonical", 0, full_range=True)
print(
    "Complete Holdem game accepts wagers outside numeric action slots PASS", flush=True
)
