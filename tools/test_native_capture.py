"""Exercise complete native Cosino play against an isolated local HTTP sentinel."""

import argparse
import base64
import http.server
import json
import math
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import uuid
from pathlib import Path


def strict_object(text):
    def pairs(entries):
        result = {}
        for key, value in entries:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result

    def finite(value):
        if isinstance(value, float) and not math.isfinite(value):
            raise ValueError("nonfinite number")
        if isinstance(value, dict):
            for item in value.values():
                finite(item)
        if isinstance(value, list):
            for item in value:
                finite(item)

    value = json.loads(
        text[text.index("{") : text.rindex("}") + 1], object_pairs_hook=pairs
    )
    finite(value)
    return value


def supplied_equal(raw, applied):
    if type(raw) is not type(applied):
        return False
    if isinstance(raw, dict):
        return all(
            key in applied and supplied_equal(value, applied[key])
            for key, value in raw.items()
        )
    return raw == applied


def check_evidence(output, calls, mode):
    records = [
        json.loads(line)
        for line in (output / "trajectory.jsonl").read_text().splitlines()
    ]
    rows = [row for row in records if row["event_type"] == "decision"]
    summary = records[-1]
    by_id = {call["call_id"]: call for call in calls}
    call_indices = {call["call_id"]: index for index, call in enumerate(calls)}
    seen = set()
    statuses = {"accepted": 0, "rejected": 0, "fallback": 0, "missing": 0}
    gaps = 0
    for row in rows:
        statuses[row["action_status"]] += 1
        execution = row["observation"]["native_execution"]
        actor = int(row["seat"])
        actions = [
            e
            for e in execution["events"]
            if e["kind"] == "action" and e["seat"] == actor
        ]
        assert len(actions) == 1
        event = actions[0]
        sayings = [
            e["text"]
            for e in execution["events"]
            if e["kind"] == "say" and e["seat"] == actor
        ]
        actual = {"action": event["action"], "say": sayings[0] if sayings else ""}
        if event["action"] in ("bet", "raise"):
            actual["amount"] = event["amount"]
        assert actual == row["executed_action"]
        if actor != 0:
            assert not row["attempts"] and row["selected_attempt_id"] is None
            continue
        if mode == "retry":
            assert len(row["attempts"]) == 2
            assert not row["attempts"][0]["accepted"]
            assert row["attempts"][0]["rejection_reason"] is not None
            assert row["selected_attempt_id"] == row["attempts"][1]["attempt_id"]
        for index, attempt in enumerate(row["attempts"]):
            cid = attempt["platform_call_id"]
            # An intentionally overbound header map is omitted as a whole, including its IDs.
            if cid is None:
                assert mode == "throttle-auth" and row["observation"]["capture_errors"]
                candidates = [c for c in calls if c["call_id"] not in seen]
                assert len(candidates) == 1
                call = candidates[0]
                cid = call["call_id"]
            else:
                call = by_id[cid]
            seen.add(cid)
            if mode == "mixed":
                # The first of nine declared wire replies is a supported fence with an omitted default.
                # Every other reply supplies a changed value/type, ignored key, duplicate or nonfinite value.
                if call_indices[cid] % 9 == 0:
                    assert attempt["accepted"] and row["action_status"] == "accepted"
                else:
                    assert (
                        not attempt["accepted"] and row["action_status"] == "rejected"
                    )
            assert attempt["request"] == json.loads(call["request_body"])
            wire = row["observation"]["native_requests"][index]
            assert wire["raw_body"] == call["request_body"]
            assert base64.b64decode(wire["body_b64"]).decode() == call["request_body"]
            assert set(wire["headers"]) <= {
                "content-type",
                "anthropic-version",
                "X-Coworld-Player-Slot",
            }
            assert wire["headers"]["X-Coworld-Player-Slot"] == "0"
            if len(call["response_body"].encode()) > 65536:
                assert (
                    attempt["raw_response"] is None
                    and attempt["response_body_b64"] is None
                )
                assert row["observation"]["capture_errors"]
                gaps += 1
            else:
                assert attempt["raw_response"] == call["response_body"]
                assert (
                    base64.b64decode(attempt["response_body_b64"]).decode()
                    == call["response_body"]
                )
            assert attempt["http_status"] == call["status"]
            assert attempt["response_complete"] and attempt["response_reader_joined"]
            if attempt["response_headers"] is not None:
                headers = {k.lower(): v for k, v in attempt["response_headers"].items()}
                assert headers["x-softmax-llm-call-id"] == cid
                assert attempt["provider_request_id"] == "local-request-" + cid
            else:
                assert row["observation"]["capture_errors"]
                gaps += 1
            if mode == "strict-json":
                label = call["fixture_case"]
                if label in {"positive-fence", "negative-usage", "zero-usage"}:
                    assert attempt["accepted"]
                else:
                    assert (
                        not attempt["accepted"]
                        and row["selected_attempt_id"] != attempt["attempt_id"]
                    )
                if label == "negative-usage":
                    assert (
                        attempt["input_tokens"] is None
                        and attempt["output_tokens"] is None
                    )
                if label == "zero-usage":
                    assert (
                        attempt["input_tokens"] == 0 and attempt["output_tokens"] == 0
                    )
            if attempt["accepted"]:
                assert attempt["rejection_reason"] is None
                assert row["selected_attempt_id"] == attempt["attempt_id"]
                assert supplied_equal(strict_object(attempt["response"]), actual)
                assert attempt["parsed_action"] == actual
                assert 200 <= attempt["http_status"] < 300
        if row["action_status"] != "accepted":
            assert row["selected_attempt_id"] is None
    assert seen == set(by_id)
    if mode == "strict-json":
        assert {c["fixture_case"] for c in calls} == {
            "trailing-object",
            "trailing-array",
            "comment",
            "leading-zero",
            "plus-number",
            "invalid-escape",
            "depth-bound",
            "non-json-whitespace",
            "positive-fence",
            "negative-usage",
            "zero-usage",
        }
        assert summary["status"] == "truncated"
    if mode == "mixed":
        assert statuses["accepted"] and statuses["rejected"]
    if mode == "throttle-auth":
        assert len(calls) == 2 and [c["status"] for c in calls] == [429, 401]
        assert statuses["fallback"] and gaps == 2 and summary["status"] == "failed"
        assert "private capture publication failed" in (output / "game.log").read_text()
    return {
        "decisions": len(rows),
        "statuses": statuses,
        "explicit_evidence_gaps": gaps,
    }


def check_unicode(output, calls, original_source):
    def scalar(value):
        if isinstance(value, str):
            value.encode("utf8")
        elif isinstance(value, dict):
            for key, item in value.items():
                scalar(key)
                scalar(item)
        elif isinstance(value, list):
            for item in value:
                scalar(item)

    raw = (output / "trajectory.jsonl").read_bytes()
    try:
        records = [json.loads(line) for line in raw.decode("utf8").splitlines()]
        scalar(records)
        valid = True
    except (UnicodeError, json.JSONDecodeError):
        valid = False
    if original_source:
        assert not valid, (
            "original native source did not reproduce unsafe private serialization"
        )
        return {
            "expected_original_invalid_private_json": True,
            "authenticated_targets": 0,
        }
    assert valid and records[-1]["status"] == "failed"
    wire = {call["call_id"]: call for call in calls}
    seen, controls = set(), set()
    forensic = 0
    for row in records[:-1]:
        observation = row["observation"]
        if "invalid_native_evidence_json_b64" in observation:
            forensic += 1
            assert (
                row["selected_attempt_id"] is None
                and row["executed_action"] is None
                and row["attempts"] == []
            )
            assert row["action_status"] in {"rejected", "fallback"}
            source = json.loads(
                base64.b64decode(
                    observation["invalid_native_evidence_json_b64"], validate=True
                ).decode("utf8", errors="surrogateescape")
            )
            attempts, observation = source["attempts"], source["observation"]
        else:
            attempts = row["attempts"]
        for index, attempt in enumerate(attempts):
            identity = attempt["platform_call_id"]
            if identity is None:
                continue  # No received-call identity remains a visible stage gap, never a synthetic receipt.
            uuid.UUID(identity)
            call = wire[identity]
            assert attempt["response_body_b64"] == call["response_body_b64"]
            assert (
                observation["native_requests"][index]["body_b64"]
                == call["request_body_b64"]
            )
            seen.add(identity)
            if call["fixture_case"] in {"positive-accent", "positive-pair"}:
                assert attempt["accepted"] and row["action_status"] == "accepted"
                assert row["executed_action"]["say"] == (
                    "café" if call["fixture_case"] == "positive-accent" else "😀"
                )
                controls.add(call["fixture_case"])
    assert (
        seen == set(wire)
        and forensic
        and controls == {"positive-accent", "positive-pair"}
    )
    return {
        "strict_scalar_json": True,
        "forensic_rows": forensic,
        "all_raw_HTTP_bodies_joined": len(seen),
        "authenticated_targets": 0,
    }


def main():
    parent_clean = {
        key: os.environ[key]
        for key in ("PATH", "HOME", "TMPDIR", "LANG")
        if key in os.environ
    }
    if set(os.environ) - set(parent_clean) - {"LC_CTYPE", "__CF_USER_TEXT_ENCODING"}:
        os.execve(sys.executable, [sys.executable, *sys.argv], parent_clean)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, required=True)
    parser.add_argument("--player", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--variant", default="kuhn")
    parser.add_argument("--expect-missing", action="store_true")
    parser.add_argument("--no-capture", action="store_true")
    parser.add_argument("--ordinary-clock", action="store_true")
    parser.add_argument("--expect-original-unicode", action="store_true")
    parser.add_argument(
        "--mode",
        choices=["normal", "mixed", "retry", "throttle-auth", "strict-json", "unicode"],
        default="normal",
    )
    parser.add_argument(
        "--registration-case",
        choices=[
            "missing",
            "late",
            "malformed",
            "scripted",
            "external",
            "disconnect",
            "replacement",
            "scripted-external",
        ],
    )
    parser.add_argument("--expect-registration-bug", action="store_true")
    parser.add_argument("--http-budget-state", type=Path)
    args = parser.parse_args()
    registration = args.registration_case
    component = args.mode in {"strict-json", "unicode"} or bool(registration)
    assert not args.expect_original_unicode or args.mode == "unicode"
    os.umask(0o077)
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    calls = []
    protocol_errors = []
    ws_clients = []

    class Sentinel(http.server.BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            pass

        def do_PUT(self):
            assert self.path == "/private-trajectory" and args.mode == "throttle-auth"
            body = self.rfile.read(int(self.headers["Content-Length"]))
            (output / "trajectory.jsonl").write_bytes(body)
            # The original game-authored bytes survive even though publication fails.
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_POST(self):
            if self.path == "/private-trajectory":
                return self.do_PUT()
            assert self.path == "/v1/messages"
            length = int(self.headers["Content-Length"])
            assert 0 < length < 65536 and len(calls) < (32 if component else 440)
            body = self.rfile.read(length)
            request = json.loads(
                body.decode("utf8", errors="surrogateescape")
                if args.mode == "unicode"
                else body
            )
            assert request["model"] == "local/cosino-capture-sentinel"
            slot = self.headers["X-Coworld-Player-Slot"]
            call = str(uuid.uuid4())
            text = '{"action":"fold","say":""}'
            status = 200
            user = request["messages"][0]["content"]
            if args.mode == "mixed":
                cases = [
                    '```json\n{"action":"fold"}\n```',
                    '{"action":"FOLD","say":""}',
                    '{"action":"fold","say":false}',
                    '{"action":"fold","say":"","ignored":1}',
                    '{"action":"fold","action":"fold","say":""}',
                    '{"action":"fold","amount":1e999,"say":""}',
                    '{"action":"bet","amount":999,"say":""}'
                    if '"bet" (the wager' in user
                    else '{"action":"fold","amount":999,"say":""}',
                    '{"action":"fold","say":"' + "x" * 121 + '"}',
                    '{"action":"call","say":""}'
                    if '"check"' in user
                    else '{"action":" fold ","say":""}',
                ]
                text = cases[len(calls) % len(cases)]
            elif args.mode == "retry" and "Your previous reply was invalid" not in user:
                text = "local malformed first reply"
            elif args.mode == "throttle-auth":
                status = 429 if not calls else 401
                text = "local throttle" if status == 429 else "local disabled auth"
            fixture_case = None
            if args.mode == "strict-json":
                cases = [
                    ("trailing-object", '{"action":"fold",}'),
                    ("trailing-array", '{"action":"fold","ignored":[1,]}'),
                    ("comment", '{"action":"fold"/*local*/}'),
                    ("leading-zero", '{"action":"fold","amount":01}'),
                    ("plus-number", '{"action":"fold","amount":+1}'),
                    ("invalid-escape", '{"action":"fold","say":"\\q"}'),
                    (
                        "depth-bound",
                        '{"action":"fold","ignored":' + "[" * 34 + "0" + "]" * 34 + "}",
                    ),
                    ("non-json-whitespace", '{\v"action":"fold"}'),
                    ("positive-fence", '```json\n{"action":"fold"}\n```'),
                    ("negative-usage", '{"action":"fold"}'),
                    ("zero-usage", '{"action":"fold"}'),
                ]
                fixture_case, text = cases[min(len(calls), len(cases) - 1)]
            invalid = None
            if args.mode == "unicode":
                cases = [
                    (
                        "positive-accent",
                        '```json\n{"action":"fold","say":"caf\\u00e9"}\n```',
                        None,
                    ),
                    ("positive-pair", '{"action":"fold","say":"\\ud83d\\ude00"}', None),
                    ("metadata", '{"action":"fold","say":"safe"}', None),
                    ("lone-low", '{"action":"fold","say":"\\udc00"}', None),
                    ("low-key", '{"action":"fold","\\udc00":1}', None),
                    ("raw-invalid", '{"action":"fold","say":"INVALID_BYTES"}', b"\x80"),
                    ("clear", '{"action":"fold","say":"clear"}', None),
                    (
                        "overlong",
                        '{"action":"fold","say":"INVALID_BYTES"}',
                        b"\xc0\x80",
                    ),
                    ("lone-high", '{"action":"fold","say":"\\ud800"}', None),
                    (
                        "out-of-range",
                        '{"action":"fold","say":"INVALID_BYTES"}',
                        b"\xf4\x90\x80\x80",
                    ),
                    (
                        "continuation",
                        '{"action":"fold","say":"INVALID_BYTES"}',
                        b"\xe2\x28\xa1",
                    ),
                    (
                        "truncated",
                        '{"action":"fold","say":"INVALID_BYTES"}',
                        b"\xe2\x82",
                    ),
                    ("later-safe", '{"action":"fold","say":"safe"}', None),
                ]
                fixture_case, text, invalid = cases[min(len(calls), len(cases) - 1)]
            response = {
                "id": "local-message-" + call,
                "type": "message",
                "role": "assistant",
                "model": "local/cosino-capture-sentinel",
                "content": [{"type": "text", "text": text}],
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 1, "output_tokens": 1},
            }
            if fixture_case == "negative-usage":
                response["usage"] = {"input_tokens": -3, "output_tokens": -5}
            elif fixture_case == "zero-usage":
                response["usage"] = {"input_tokens": 0, "output_tokens": 0}
            if status != 200:
                response = {"error": {"message": text}}
                if status == 429:
                    response["padding"] = "x" * 70000
            if fixture_case == "metadata":
                response["model"] = "bad\udc00"
            encoded = json.dumps(response).encode()
            if invalid is not None:
                encoded = encoded.replace(b"INVALID_BYTES", invalid)
            calls.append(
                {
                    "slot": slot,
                    "call_id": call,
                    "request_body": body.decode("utf8", errors="surrogateescape")
                    if args.mode == "unicode"
                    else body.decode(),
                    "response_body": encoded.decode("utf8", errors="surrogateescape")
                    if args.mode == "unicode"
                    else encoded.decode(),
                    "request_body_b64": base64.b64encode(body).decode(),
                    "response_body_b64": base64.b64encode(encoded).decode(),
                    "status": status,
                    "fixture_case": fixture_case,
                }
            )
            calls[-1]["elapsed_seconds"] = time.monotonic() - started
            if args.http_budget_state:
                budget = json.loads(args.http_budget_state.read_text())
                budget["count"] += 1
                args.http_budget_state.write_text(json.dumps(budget) + "\n")
                if budget["count"] > budget["cap"]:
                    protocol_errors.append("aggregate HTTP bound")
            with (output / "http-calls.jsonl").open("a") as archive:
                archive.write(json.dumps(calls[-1]) + "\n")
            if not registration:
                assert slot == "0"
                assert "native fixture only" in request["messages"][0]["content"]
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("X-Softmax-Llm-Call-Id", call)
            self.send_header("request-id", "local-request-" + call)
            if fixture_case == "metadata":
                self.send_header("X-Local-Invalid", "\x80")
            if status == 401:
                self.send_header("local-overbound-header", "x" * 17000)
            self.end_headers()
            self.wfile.write(encoded)

    fixture = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Sentinel)
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    manifest = json.loads(Path("coworld_manifest_template.json").read_text())
    config = next(
        v["game_config"] for v in manifest["variants"] if v["id"] == args.variant
    ).copy()
    seats = len(config["players"])
    config.update(
        tokens=[f"local-token-{s}" for s in range(seats)],
        seed=1,
    )
    if not args.ordinary_clock and args.mode != "unicode" and not registration:
        config.update(turnDelayMs=0, player_connect_timeout_seconds=10)
    if registration:
        config["player_connect_timeout_seconds"] = 1
    (output / "config.json").write_text(json.dumps(config))
    if registration:
        (output / "registration-contract.json").write_text(
            json.dumps(
                {
                    "case": "external"
                    if registration == "scripted-external"
                    else registration,
                    "registration_profile": registration,
                    "control_sequence": ["scripted-rock", "external"]
                    if registration == "scripted-external"
                    else [registration],
                    "prompt": "native fixture only",
                    "external_action": "fold",
                    "transport_connection_field": "UNRESOLVED: independently retained WS chronology does not bind every predecision connection vector",
                },
                indent=2,
            )
            + "\n"
        )
    # An allowlist prevents inherited provider credentials or remote endpoints reaching either runnable.
    clean = {
        k: os.environ[k] for k in ("PATH", "HOME", "TMPDIR", "LANG") if k in os.environ
    }
    with socket.socket() as available:
        available.bind(("127.0.0.1", 0))
        port = available.getsockname()[1]
    env = clean | {
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": str(port),
        "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
        "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
        "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
        "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
        "COWORLD_EPISODE_ID": "local-native-system-fixture",
        "COWORLD_GAME_VERSION": "local-system-fixture",
        "COWORLD_SOURCE_REVISION": "local-system-fixture",
        "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{fixture.server_port}",
        "COWORLD_LLM_MODEL": "local/cosino-capture-sentinel",
    }
    if component:
        env["COWORLD_TIMEOUT_SECONDS"] = (
            "20" if registration else "42"  # Explicit partial component only.
        )
    if args.no_capture:
        del env["COGAME_SAVE_TRAJECTORY_URI"]
    elif args.mode == "throttle-auth":
        env["COGAME_SAVE_TRAJECTORY_URI"] = (
            f"http://127.0.0.1:{fixture.server_port}/private-trajectory"
        )
    processes, logs = [], []
    audit = []

    def command_audit(command, child_env, role):
        # Names only: credentials and private response values never enter the audit.
        assert not any(
            key.startswith(("ANTHROPIC_", "AWS_", "BEDROCK_", "OPENAI_"))
            for key in child_env
        )
        assert set(clean) <= {"PATH", "HOME", "TMPDIR", "LANG"}
        audit.append(
            {
                "command": command,
                "role": role,
                "parent_env_keys": sorted(os.environ),
                "child_env_keys": sorted(child_env),
                "provider_credentials_absent": True,
                "routing": "explicit loopback sentinel only",
            }
        )
        (output / "environment-audit.json").write_text(
            json.dumps(audit, indent=2) + "\n"
        )

    started = time.monotonic()
    try:
        log = (output / "game.log").open("w")
        logs.append(log)
        command_audit([str(args.game.resolve())], env, "game")
        game = subprocess.Popen(
            [str(args.game.resolve())], env=env, stdout=log, stderr=subprocess.STDOUT
        )
        processes.append(game)
        healthy_by = time.monotonic() + 20
        while True:
            assert game.poll() is None, "native game exited before health probe"
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/healthz", timeout=1
                ):
                    break
            except OSError:
                assert time.monotonic() < healthy_by, "native health deadline"
                time.sleep(0.05)
        if registration:
            import websocket

            def wire_send(client, value):
                client.send(json.dumps(value))
                with (output / "registration-wire.jsonl").open("a") as stream:
                    stream.write(
                        json.dumps(
                            {
                                "elapsed_seconds": time.monotonic() - started,
                                "sent": value,
                            }
                        )
                        + "\n"
                    )

            url = f"ws://127.0.0.1:{port}/player?slot=0&token=local-token-0"
            controller = websocket.create_connection(url, timeout=1)
            ws_clients.append(controller)
            controller.recv()  # welcome: ownership has been installed before any frame.
            native = {
                "type": "prompt",
                "prompt": "native fixture only",
                "scripted": False,
                "baseline": "house",
            }
            if registration == "malformed":
                for value in [
                    {"type": "prompt"},
                    {"type": "prompt", "prompt": 7},
                    {
                        "type": "prompt",
                        "prompt": "native fixture only",
                        "scripted": "false",
                    },
                    {"type": "prompt", "prompt": "native fixture only", "baseline": 7},
                ]:
                    wire_send(controller, value)
            elif registration == "scripted":
                wire_send(controller, native | {"scripted": True, "baseline": "rock"})
            elif registration in {"external", "scripted-external"}:
                if registration == "scripted-external":
                    wire_send(
                        controller, native | {"scripted": True, "baseline": "rock"}
                    )
                    until = time.monotonic() + 3
                    while "scripted rock" not in (output / "game.log").read_text():
                        assert time.monotonic() < until
                        time.sleep(0.01)
                wire_send(controller, {"type": "register", "control": "external"})
                if registration == "scripted-external":
                    until = time.monotonic() + 3
                    while (
                        "registered external control"
                        not in (output / "game.log").read_text()
                    ):
                        assert time.monotonic() < until
                        time.sleep(0.01)
            elif registration in {"disconnect", "replacement"}:
                wire_send(controller, native)
            if registration == "replacement":
                previous = controller
                controller = websocket.create_connection(url, timeout=1)
                ws_clients.append(controller)
                controller.recv()
                wire_send(controller, native | {"scripted": True, "baseline": "rock"})
                # Wait for the existing source acknowledgement log before starting the other seat.
                until = time.monotonic() + 3
                while "scripted rock" not in (output / "game.log").read_text():
                    assert time.monotonic() < until
                    time.sleep(0.01)
                wire_send(previous, native)
                wire_send(previous, {"type": "register", "control": "external"})
                wire_send(previous, {"type": "action", "id": 1, "kind": "fold"})
                previous.close()

            def controller_loop():
                delivered = False
                disconnected = False
                while game.poll() is None:
                    try:
                        frame = json.loads(controller.recv())
                    except websocket.WebSocketTimeoutException:
                        continue
                    except (
                        websocket.WebSocketException,
                        OSError,
                        json.JSONDecodeError,
                    ):
                        return
                    with (output / "registration-wire.jsonl").open("a") as stream:
                        stream.write(
                            json.dumps(
                                {
                                    "elapsed_seconds": time.monotonic() - started,
                                    "received": frame,
                                }
                            )
                            + "\n"
                        )
                    if (
                        registration in {"external", "scripted-external"}
                        and frame.get("type") == "observation"
                    ):
                        wire_send(
                            controller,
                            {
                                "type": "action",
                                "id": frame["id"],
                                "kind": "fold",
                                "say": "",
                            },
                        )
                    acted = any(
                        e.get("kind") == "action" and e.get("seat") == 0
                        for e in frame.get("events", [])
                    )
                    if registration in {"scripted", "external"} and acted:
                        controller.close()
                        return
                    if registration == "late" and acted and not delivered:
                        delivered = True
                        wire_send(controller, native)
                    if registration == "disconnect" and acted and not disconnected:
                        disconnected = True
                        controller.close()
                        return

            threading.Thread(target=controller_loop, daemon=True).start()
        for seat in range(1 if registration else 0, seats):
            player_env = clean | {
                "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=local-token-{seat}"
            }
            player_env.update(
                {"PLAYER_PROMPT": "native fixture only"}
                if seat == 0
                else {"PLAYER_SCRIPTED": "house"}
            )
            log = (output / f"player-{seat}.log").open("w")
            logs.append(log)
            command_audit([str(args.player.resolve())], player_env, "player")
            processes.append(
                subprocess.Popen(
                    [str(args.player.resolve())],
                    env=player_env,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                )
            )
        next_measurement = 0.0
        partial_finished = False
        while game.poll() is None:
            assert not protocol_errors, protocol_errors
            assert time.monotonic() - started < (30 if component else 180), (
                "native absolute wall guard"
            )
            size = sum(p.stat().st_size for p in output.rglob("*") if p.is_file())
            assert (
                size
                <= (8 if args.mode == "unicode" else 4 if component else 24)
                * 1024
                * 1024
            ), "native per-fixture artifact bound"
            if component and all(
                (output / name).is_file()
                for name in ["trajectory.jsonl", "results.json", "replay.json"]
            ):
                partial_finished = True
                break  # Native terminal artifacts complete; do not wait through the20s shutdown grace.
            if time.monotonic() >= next_measurement:
                measurement = {
                    "elapsed_seconds": time.monotonic() - started,
                    "http_calls": len(calls),
                    "artifact_bytes": size,
                    "disk_free_bytes": shutil.disk_usage(output).free,
                    "live_owned_processes": sum(p.poll() is None for p in processes),
                }
                try:
                    measured = subprocess.run(
                        [
                            "ps",
                            "-o",
                            "pid=,rss=,time=",
                            "-p",
                            ",".join(str(p.pid) for p in processes),
                        ],
                        capture_output=True,
                        env=clean,
                        text=True,
                        check=True,
                        timeout=2,
                    )
                    measurement["process_resources"] = [
                        {
                            "pid": int(parts[0]),
                            "rss_kib": int(parts[1]),
                            "cpu_time_hms": parts[2],
                        }
                        for line in measured.stdout.splitlines()
                        if len(parts := line.split()) == 3
                    ]
                except (OSError, subprocess.SubprocessError) as error:
                    measurement["process_resources"] = None
                    measurement["resource_gap"] = type(error).__name__
                with (output / "metrics.jsonl").open("a") as metrics:
                    metrics.write(json.dumps(measurement) + "\n")
                next_measurement = time.monotonic() + 1
            time.sleep(0.2)
        assert partial_finished if component else game.returncode == 0
        for process in processes[1:]:
            assert process.wait(timeout=2 if component else 10) == 0
        results = json.loads(
            (output / "results.json")
            .read_bytes()
            .decode("utf8", errors="surrogateescape")
            if args.mode == "unicode"
            else (output / "results.json").read_text()
        )
        if component:
            assert (
                results["reason"] == "deadline"
                and results["handsPlayed"] < config["hands"]
            )
        else:
            assert (
                results["reason"] == "complete"
                and results["handsPlayed"] == config["hands"]
            )
        if not registration:
            assert calls, "no native loopback model requests"
        else:
            records = [
                json.loads(line)
                for line in (output / "trajectory.jsonl").read_text().splitlines()
            ]
            own = [
                row
                for row in records
                if row.get("event_type") == "decision" and row["seat"] == "0"
            ]
            if args.expect_registration_bug:
                assert calls, "predicted old registration bug did not reproduce"
            elif registration in {
                "missing",
                "malformed",
                "scripted",
                "external",
                "replacement",
                "scripted-external",
            }:
                assert not calls, "registration profile made unexpected native HTTP"
            elif registration == "late":
                assert calls and any(
                    row["observation"]["native_registration"]["registered"] is False
                    for row in own
                )
                assert any(row["attempts"] for row in own)
            elif registration == "disconnect":
                assert calls and any(
                    row["attempts"]
                    and not row["observation"]["native_registration"]["connected"]
                    for row in own
                ), "delivered native strategy did not survive disconnect"
        (output / "http-calls.json").write_text(json.dumps(calls, indent=2) + "\n")
        trajectory = output / "trajectory.jsonl"
        if args.expect_missing or args.no_capture:
            assert not trajectory.exists(), (
                "baseline unexpectedly writes native private capture"
            )
        else:
            assert trajectory.is_file(), (
                "full native game omitted requested private model trajectory"
            )
        evidence = (
            (
                check_unicode(output, calls, args.expect_original_unicode)
                if args.mode == "unicode"
                else check_evidence(output, calls, args.mode)
            )
            if trajectory.exists() and not registration
            else None
        )
        print(
            json.dumps(
                {
                    "registration_case": registration,
                    "old_bug_reproduced": bool(
                        registration and args.expect_registration_bug
                    ),
                    "variant": args.variant,
                    "mode": args.mode,
                    "capture_enabled": not args.no_capture,
                    "partial_component": component,
                    "native_reason": results["reason"],
                    "hands": results["handsPlayed"],
                    "local_http_calls": len(calls),
                    "private_capture_exists": trajectory.exists(),
                    "real_provider_calls": 0,
                    "elapsed_seconds": time.monotonic() - started,
                    "evidence": evidence,
                }
            )
        )
    finally:
        for client in ws_clients:
            try:
                client.close()
            except (websocket.WebSocketException, OSError) as error:
                with (output / "socket-close-errors.jsonl").open("a") as stream:
                    stream.write(json.dumps({"type": type(error).__name__}) + "\n")
        for process in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        fixture.shutdown()
        for log in logs:
            log.close()
        (output / "owned-terminal-processes.json").write_text(
            json.dumps(
                [
                    {"pid": process.pid, "returncode": process.poll()}
                    for process in processes
                ],
                indent=2,
            )
            + "\n"
        )


if __name__ == "__main__":
    main()
