"""Check complete private candidate matches for every published poker table."""
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VARIANTS = ("kuhn", "leduc", "holdem-hu", "holdem-6max", "headsup", "sixmax")

if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    families: dict[str, set[str]] = {}
    with tempfile.TemporaryDirectory() as temp:
        for variant in VARIANTS:
            output = Path(temp) / variant
            subprocess.run([str(binary), str(output), "10", "1", variant], cwd=ROOT, check=True)
            manifest = json.loads((output / "manifest.json").read_text())
            assert len(manifest["runs"]) == 10
            source = output / "trajectories.jsonl"
            assert source.stat().st_mode & 0o777 == 0o600
            decisions, episodes, terminals = 0, 0, 0
            with source.open() as stream:
                for line in stream:
                    row = json.loads(line)
                    assert row["game"] == "cosino" and row["source_revision"] == manifest["source_revision"]
                    if row["event_type"] == "episode":
                        run = manifest["runs"][episodes]
                        assert row["status"] == "completed" and decisions == run["decisions"]
                        assert terminals == 1 and decisions > 0
                        assert row["outcome"]["reason"] == "complete"
                        assert row["outcome"]["net"] == run["net"] and sum(run["net"]) == 0
                        assert row["outcome"]["hands"] == run["hands"]
                        assert row["outcome"]["fallbacks"] == row["outcome"]["forced_folds"] == 0
                        scores = [value["score"] for value in row["participant_outcomes"].values()]
                        assert all(0 <= score <= 1 for score in scores) and abs(sum(scores) - 1) < 1e-9
                        families.setdefault(row["seed_family"], set()).add(variant)
                        decisions = terminals = 0
                        episodes += 1
                        continue
                    assert row["event_type"] == "decision" and row["visibility"] == "private"
                    assert row["decision_index"] == decisions and terminals == 0
                    decisions += 1
                    terminals += row["terminal"]
                    attempt, = row["attempts"]
                    assert attempt["origin"] == "teacher" and attempt["policy"] == "scripted-house"
                    assert attempt["request"] is None and attempt["platform_call_id"] is None
                    assert attempt["behavior_logprobs"] is None
                    assert json.loads(attempt["response"]) == attempt["parsed_action"]
                    metadata = row["observation"]["prompt_template"]
                    for message in attempt["prompt"]:
                        assert metadata[message["role"] + "_sha256"].lower() == hashlib.sha256(message["content"].encode()).hexdigest()
                    assert row["action_status"] == "accepted" and attempt["accepted"]
                    assert row["selected_attempt_id"] == attempt["attempt_id"]
                    assert row["executed_action"] == attempt["parsed_action"]
            assert episodes == 10 and decisions == 0
            print(variant, "10 complete private source matches PASS", flush=True)
    assert len(families) == 10 and all(tables == set(VARIANTS) for tables in families.values())
