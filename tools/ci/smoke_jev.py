"""Exercise player-side Jev and normal scripted players in Cosino containers."""

import json
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class MockSystemOne(BaseHTTPRequestHandler):
    choices: list[str] = []
    headers_seen: list[tuple[str | None, str | None]] = []

    def do_POST(self) -> None:
        assert self.path == "/v1/systemone"
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        observation = json.loads(request["state"].split("Your seat observation:\n", 1)[1])
        assert observation["game"] == "cosino"
        assert not {"config", "policyNames", "pair", "mirror"} & observation.keys()
        serialized = json.dumps(observation)
        assert all(f'"{key}":' not in serialized for key in
                   ("seed", "pair", "mirror", "policyNames"))
        assert all(event["kind"] not in {"calib", "audit"} for event in observation["events"])
        assert all(event["kind"] != "deal" or event["seat"] == observation["slot"]
                   for event in observation["events"])
        for slot, seat in enumerate(observation["seats"]):
            if slot != observation["slot"] and not seat["revealed"]:
                assert seat["cards"] == []
        for option in observation["actionSpace"]:
            if option["kind"] in {"bet", "raise"}:
                assert 0 < option["min"] <= option["max"]
        criteria = request["questions"]["decision"]["criteria"]
        choice = next((name for name in criteria if name.startswith("bet ")), None)
        choice = choice or next((name for name in criteria if name.startswith("raise ")), None)
        choice = choice or next((name for name in criteria if name in {"check", "call"}), None)
        choice = choice or "fold"
        assert choice in criteria
        self.choices.append(choice)
        self.headers_seen.append((self.headers.get("authorization"),
                                  self.headers.get("x-coworld-player-slot")))
        reply = {
            "model": "mock-jev",
            "answers": {"decision": {
                "type": "choice", "confidence": 1.0,
                "probabilities": {name: float(name == choice) for name in criteria},
            }},
            "usage": {"input_tokens": 1, "output_tokens": 1},
        }
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format: str, *args: object) -> None:
        pass


def free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def main() -> None:
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    image = sys.argv[2] if len(sys.argv) > 2 else "cosino-jev-25001:local"
    cases = [
        ("kuhn", "kuhn", 2, 0, False),
        ("leduc", "leduc", 2, 1, False),
        ("holdem-hu", "holdem", 2, 0, False),
        ("holdem-6max", "holdem", 6, 3, False),
        ("headsup", "holdem", 2, 1, True),
        ("sixmax", "holdem", 6, 3, True),
    ]
    mock = ThreadingHTTPServer(("0.0.0.0", 0), MockSystemOne)
    thread = threading.Thread(target=mock.serve_forever, daemon=True)
    thread.start()
    try:
        for name, variant, seats, jev_slot, chip_race in cases:
            MockSystemOne.choices = []
            MockSystemOne.headers_seen = []
            port = free_port()
            episode = output / name
            episode.mkdir(exist_ok=True)
            tokens = [f"cosino-{slot}" for slot in range(seats)]
            config = {
                "tokens": tokens,
                "players": [{"name": "Jev" if slot == jev_slot else f"House {slot}"}
                            for slot in range(seats)],
                "seed": 7, "variant": variant,
                "startingStack": {"kuhn": 20, "leduc": 50,
                                  "holdem": 100}[variant],
                "ante": 1 if variant != "holdem" else 0,
                "smallBlind": 0 if variant != "holdem" else 1,
                "bigBlind": 0 if variant != "holdem" else 2,
                "hands": 2, "duplicate": not chip_race,
                "chipRace": chip_race, "randomiseSeating": False,
                "turnDelayMs": 0, "llmTimeoutSeconds": 5,
                "player_connect_timeout_seconds": 60.0,
            }
            game_name = f"cosino-jev-smoke-{name}"
            game_log = (episode / "game.log").open("w")
            game = subprocess.Popen([
                "docker", "run", "--rm", "--platform=linux/amd64",
                "--add-host=host.docker.internal:host-gateway",
                "--name", game_name, "-p", f"{port}:8080",
                "-v", f"{episode}:/out", image, "/bin/cosino",
                "--config:" + json.dumps(config, separators=(",", ":")),
                "--results-uri:file:///out/results.json",
                "--save-replay-uri:file:///out/replay.json",
            ], stdout=game_log, stderr=subprocess.STDOUT)
            players = []
            try:
                ready = False
                for _ in range(150):
                    if game.poll() is not None:
                        break
                    if subprocess.run([
                        "curl", "-fsS", "--max-time", "1",
                        f"http://127.0.0.1:{port}/healthz",
                    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                        ready = True
                        break
                    time.sleep(0.1)
                assert ready and game.poll() is None, (episode / "game.log").read_text()
                for slot in range(seats):
                    env = ["-e", f"COWORLD_PLAYER_WS_URL=ws://host.docker.internal:{port}/player?slot={slot}&token={tokens[slot]}"]
                    if slot == jev_slot:
                        env += ["-e", "PLAYER_JEV=1"]
                        if name == "kuhn":
                            env += ["-e", f"METTA_CAPTURE_URL=http://host.docker.internal:{mock.server_port}", "-e", "METTA_CAPTURE_KEY=mock"]
                        else:
                            env += ["-e", f"AWS_ENDPOINT_URL_BEDROCK_RUNTIME=http://host.docker.internal:{mock.server_port}"]
                    else:
                        env += ["-e", "PLAYER_SCRIPTED=house"]
                    log = (episode / f"player-{slot}.log").open("w")
                    player = subprocess.Popen([
                        "docker", "run", "--rm", "--platform=linux/amd64",
                        "--add-host=host.docker.internal:host-gateway",
                        *env, image, "/bin/cosino-player",
                    ], stdout=log, stderr=subprocess.STDOUT)
                    players.append((player, log))
                for _ in range(1200):
                    if (episode / "results.json").exists() and (episode / "replay.json").exists():
                        break
                    if game.poll() is not None:
                        break
                    time.sleep(0.1)
                assert (episode / "results.json").exists(), (episode / "game.log").read_text()
                assert (episode / "replay.json").exists(), (episode / "game.log").read_text()
                for player, _ in players:
                    assert player.wait(timeout=10) == 0
                results = json.loads((episode / "results.json").read_text())
                replay = json.loads((episode / "replay.json").read_text())
                assert results["handsPlayed"] == 2
                assert results["fallbacks"][jev_slot] == 0
                assert results["forcedFolds"][jev_slot] == 0
                assert len(MockSystemOne.choices) == results["decisions"][jev_slot] > 0
                assert len(replay["events"]) > 0
                jev_actions = [event for event in replay["events"]
                               if event["kind"] == "action" and event["seat"] == jev_slot]
                assert len(jev_actions) == len(MockSystemOne.choices)
                for choice, event in zip(MockSystemOne.choices, jev_actions, strict=True):
                    kind, _, amount = choice.partition(" ")
                    assert event["action"] == kind
                    if amount:
                        assert event["amount"] == int(amount)
                expected_auth = ("Bearer mock", None) if name == "kuhn" else (None, str(jev_slot))
                assert MockSystemOne.headers_seen == [expected_auth] * len(MockSystemOne.choices)
                print(f"{name}: {len(MockSystemOne.choices)} accepted Jev actions, 0 fallback")
            finally:
                subprocess.run(["docker", "stop", "--time", "1", game_name],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                for player, log in players:
                    if player.poll() is None:
                        player.terminate()
                        player.wait(timeout=5)
                    log.close()
                game_log.close()
    finally:
        mock.shutdown()
        mock.server_close()


if __name__ == "__main__":
    main()
