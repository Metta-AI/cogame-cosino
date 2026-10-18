"""Published poker episodes with real players and a closed inference endpoint."""
import argparse
import hashlib
import json
import os
import socket
import subprocess
import time
from pathlib import Path


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / "coworld_manifest_template.json").read_text())
    variants = {entry["id"]: entry["game_config"] for entry in manifest["variants"]}
    cases = [(name, "canonical") for name in variants]
    cases += [("kuhn", wording) for wording in
              ("plain", "numbered", "questions", "reordered", "heldout-briefing", "heldout-reference", "mixed")]
    if args.smoke:
        cases = [("kuhn", "canonical"), ("sixmax", "canonical")]
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    for variant, wording in cases:
        work = args.output / f"{variant}-{wording}"
        work.mkdir(mode=0o700)
        config = dict(variants[variant])
        seats = config["num_agents"]
        config.update(seed=7, promptVariant=wording, promptSeed=4,
                      tokens=[f"t{seat}" for seat in range(seats)],
                      players=[{"name": f"policy-{seat}"} for seat in range(seats)])
        (work / "config.json").write_text(json.dumps(config))
        port, closed_port = free_port(), free_port()
        env = os.environ.copy()
        for key in ("ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY_URI", "AWS_BEARER_TOKEN_BEDROCK",
                    "AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "PLAYER_SCRIPTED"):
            env.pop(key, None)
        env.update(COGAME_HOST="127.0.0.1", COGAME_PORT=str(port),
                   COGAME_CONFIG_URI=(work / "config.json").as_uri(),
                   COGAME_RESULTS_URI=(work / "results.json").as_uri(),
                   COGAME_SAVE_REPLAY_URI=(work / "replay.json").as_uri(),
                   COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{closed_port}",
                   COSINO_HOST_TRACE_PATH=str(work / "host.jsonl"),
                   COSINO_ATTEMPT_TRACE_DIR=str(work / "attempts"),
                   COSINO_SOURCE_REVISION="uncommitted-cosino-validation")
        processes, logs = [], []
        try:
            log = (work / "game.log").open("w")
            logs.append(log)
            game = subprocess.Popen([str(args.game)], cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
            processes.append(game)
            for _ in range(200):
                assert game.poll() is None, work
                with socket.socket() as probe:
                    ready = probe.connect_ex(("127.0.0.1", port)) == 0
                if ready:
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError(f"host did not start: {work}")
            for seat in range(seats):
                player_env = dict(env, COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                                  PLAYER_PROMPT=f"PRIVATE-STRATEGY-{seat}: Play using your cards and the public table.")
                log = (work / f"player-{seat}.log").open("w")
                logs.append(log)
                processes.append(subprocess.Popen([str(args.player)], cwd=root, env=player_env,
                                                   stdout=log, stderr=subprocess.STDOUT))
            assert game.wait(timeout=manifest["episode_timeout_minutes"] * 60 + 30) == 0
            for player in processes[1:]:
                assert player.wait(timeout=15) == 0
            results = json.loads((work / "results.json").read_text())
            assert results["reason"] in ("complete", "budget"), results
            assert abs(sum(results["scores"]) - 1) < 1e-9
            with (work / "host.jsonl").open() as stream:
                records = [json.loads(line) for line in stream]
            assert records[0]["event_type"] == "episode_start"
            assert records[-1]["event_type"] == "episode_end" and records[-1]["results"] == results
            decisions = [row for row in records if row["event_type"] == "host_decision"]
            assert decisions and len(decisions) == sum(results["decisions"])
            assert sum(row["fallbacks"] for row in decisions) == sum(results["fallbacks"])
            assert sum(row["forced_folds"] for row in decisions) == sum(results["forcedFolds"])
            starts = {row["attempt_id"]: row for path in (work / "attempts").glob("*-start.json")
                      for row in [json.loads(path.read_text())]}
            finishes = {row["attempt_id"]: row for path in (work / "attempts").glob("*-finish.json")
                        for row in [json.loads(path.read_text())]}
            assert starts and set(starts) == set(finishes)
            assert {identity for row in decisions for identity in row["attempt_ids"]} == set(finishes)
            for row in decisions:
                assert row["source"] == "prompt" and row["policy_origin"] == "scripted-fallback"
                assert row["selected_attempt_id"] is None
                assert row["fallbacks"] == 1 and row["forced_folds"] == 0
                assert len(row["attempt_ids"]) == 2
                assert row["executed_action"] == row["proposal"]
                for identity in row["attempt_ids"]:
                    start, finish = starts[identity], finishes[identity]
                    assert finish["failure"] and not finish["parse_ok"]
                    assert finish["platform_call_id"] is None and finish["behavior_logprobs"] is None
                    system, user = (message["content"] for message in start["prompt"])
                    assert system == row["prompt"][0]["content"]
                    assert user.startswith(row["prompt"][1]["content"])
                    assert f"PRIVATE-STRATEGY-{row['seat']}" in user
                    assert all(f"PRIVATE-STRATEGY-{other}" not in user for other in range(seats) if other != row["seat"])
                    assert start["request"]["system"] == system
                    assert start["request"]["messages"][0]["content"] == user
                    assert start["model"] == start["request"]["model"]
                    metadata = start["prompt_template"]
                    assert metadata["variant"] == ("reordered" if wording == "mixed" else wording)
                    for role, text in (("system", system), ("user", user)):
                        assert metadata[f"{role}_sha256"].lower() == hashlib.sha256(text.encode()).hexdigest()
            events = json.loads((work / "replay.json").read_text())["events"]
            actions = [event for event in events if event["kind"] == "action"]
            assert len(actions) == len(decisions)
            for event, row in zip(actions, decisions, strict=True):
                assert event["seat"] == row["seat"] and event["action"] == row["executed_action"]["action"]
                if event["action"] in ("bet", "raise"):
                    assert event["amount"] == row["executed_action"]["amount"]
            public = (work / "replay.json").read_text()
            assert "PRIVATE-STRATEGY-" not in public and "prompt_template" not in public
            assert (work / "host.jsonl").stat().st_mode & 0o777 == 0o600
            for path in (work / "attempts").glob("*.json"):
                assert path.stat().st_mode & 0o777 == 0o600
            print(work.name, results["reason"], len(decisions), "applied actions;", len(starts),
                  "actual attempts;", seats, "real players PASS", flush=True)
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            for log in logs:
                log.close()


if __name__ == "__main__":
    main()
