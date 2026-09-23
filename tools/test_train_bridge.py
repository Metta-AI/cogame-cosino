"""Play every certified Cosino table through its numeric decision bridge."""

import json
import random
import subprocess
import sys
from pathlib import Path


def play(
    binary: Path,
    manifest: Path,
    variant: str,
    players: int,
    teacher: bool,
    *,
    seed: str | None = None,
    rng_seed: int = 17,
    learner_only: bool = False,
) -> None:
    process = subprocess.Popen(
        [str(binary), str(manifest), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(rng_seed)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": seed or f"cosino-{variant}-{teacher}", "players": players})
        widths = set()
        decisions = 0
        while observation["kind"] == "decision":
            encoding = request({"kind": "encode"})
            widths.add(len(encoding["values"]))
            assert encoding["decision_id"] == observation["decision_id"]
            choices = encoding["actions"]
            assert len(choices) == 7
            legal = [choice for choice in choices if choice is not None]
            assert len(legal) == len({json.dumps(choice, sort_keys=True) for choice in legal})
            view = observation["semantic_view"]
            assert observation["action_schema"]["enum"] == legal
            assert len(view["seats"]) == players
            assert all(not player["revealed_cards"] for player in view["seats"] if not player["revealed"])
            if teacher or (learner_only and observation["seat"] != 0):
                action = json.loads(request({"kind": "teacher"})["response"])
                assert action in legal
            else:
                action = rng.choice(legal)
            result = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions <= 300
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == {str(seat) for seat in range(players)}
        assert all(0 <= score <= 1 for score in observation["scores"].values())
        assert abs(sum(observation["scores"].values()) - 1) < 1e-9
        assert len(widths) == 1
        print(variant, "teacher" if teacher else "random", decisions, "decisions", widths.pop(), "features")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    for variant in ("kuhn", "leduc", "holdem-hu", "holdem-6max", "headsup", "sixmax"):
        for teacher in (True, False):
            play(binary, manifest, variant, 6 if "6max" in variant or variant == "sixmax" else 2, teacher)
    # A short-stack chip race can auto-settle a hand on blinds before another decision.
    play(binary, manifest, "headsup", 2, False, seed="stress-137", rng_seed=137 * 177 + 91, learner_only=True)
