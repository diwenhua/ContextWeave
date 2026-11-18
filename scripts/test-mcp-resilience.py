#!/usr/bin/env python3
"""Exercise the real stdio process with a blocked decoder and a recoverable database failure."""
import json
import os
from pathlib import Path
import select
import shlex
import shutil
import subprocess
import tempfile
import time

HELPER = Path(os.environ.get("CONTEXTWEAVE_MCP_BINARY", Path(__file__).resolve().parent.parent / ".build/debug/contextweave-mcp"))


def send(process, obj):
    process.stdin.write((json.dumps(obj) + "\n").encode())
    process.stdin.flush()


def receive(process, timeout=8):
    readable, _, _ = select.select([process.stdout], [], [], timeout)
    if not readable:
        raise AssertionError("MCP response timed out")
    line = process.stdout.readline()
    if not line:
        raise AssertionError("MCP process exited unexpectedly")
    return json.loads(line)


def request(identifier, method, params=None):
    return {"jsonrpc": "2.0", "id": identifier, "method": method, "params": params or {}}


def spawn(root, settings, extra=None):
    settings_path = root / "settings.json"
    settings_path.write_text(json.dumps(settings))
    env = dict(os.environ, CONTEXTWEAVE_SETTINGS=str(settings_path), **(extra or {}))
    return subprocess.Popen([str(HELPER)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, bufsize=0)


def stop(process):
    process.stdin.close()
    process.wait(timeout=10)
    assert process.returncode == 0, "MCP process exited unsuccessfully"
    assert not process.stderr.read(), "Unexpected stderr output"


def test_blocked_scan(root):
    dsh = root / "dsh"
    dsh.mkdir()
    # A complete raw Zstandard frame; the injected decoder deliberately blocks.
    payload = b"x"
    frame = bytes([0x28, 0xB5, 0x2F, 0xFD, 0x20, len(payload), (len(payload) << 3) | 1, 0, 0]) + payload
    (dsh / "session.jsonl.zstd").write_bytes(frame)
    decoded = root / "decoded.jsonl"
    decoded.write_text(json.dumps({"type": "session", "id": "test", "version": 4, "cwd": str(root / "project")}) + "\n")
    ready = root / "decoder-started"
    fake_decoder = root / "slow-zstd"
    fake_decoder.write_text("#!/bin/sh\ntouch " + shlex.quote(str(ready)) + "\nsleep 2\ncat " + shlex.quote(str(decoded)) + "\n")
    fake_decoder.chmod(0o700)
    settings = {"codexSessionsPath": str(root / "missing"), "dshSessionsPath": str(dsh), "cursorUserPath": str(root / "missing-cursor"), "antigravityPath": str(root / "missing-antigravity"), "claudeProjectsPath": str(root / "missing-claude"), "databasePath": str(root / "db.sqlite")}
    process = spawn(root, settings, {"CONTEXTWEAVE_ZSTD": str(fake_decoder)})
    try:
        send(process, request(1, "initialize", {"protocolVersion": "2025-06-18"}))
        assert receive(process)["id"] == 1
        send(process, request(2, "tools/call", {"name": "memory_scan", "arguments": {}}))
        deadline = time.monotonic() + 8
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert ready.exists(), "Injected slow scan did not start"
        started = time.monotonic()
        send(process, request(3, "ping"))
        ping = receive(process, 1)
        assert ping.get("id") == 3 and "result" in ping, "Ping was blocked by the scan"
        assert time.monotonic() - started < 1
        scan = receive(process, 8)
        assert scan.get("id") == 2 and "result" in scan
        for identifier in range(20, 45):
            send(process, request(identifier, "ping"))
        responses = [receive(process) for _ in range(25)]
        assert {response["id"] for response in responses} == set(range(20, 45))
        assert all("result" in response or response.get("error", {}).get("code") == -32000 for response in responses)
        process.stdin.write(b"not-json\n"); process.stdin.flush()
        assert receive(process)["error"]["code"] == -32700
        send(process, request(4, "ping"))
        assert receive(process).get("id") == 4, "Process did not survive malformed input"
    finally:
        stop(process)

    # A decoder that never returns must not leave the scan coalescer stuck forever.
    ready.unlink(missing_ok=True)
    process = spawn(root, dict(settings, databasePath=str(root / "timeout.sqlite")), {"CONTEXTWEAVE_ZSTD": str(fake_decoder), "CONTEXTWEAVE_ZSTD_TIMEOUT_SECONDS": "1"})
    try:
        send(process, request(5, "tools/call", {"name": "memory_scan", "arguments": {}}))
        started = time.monotonic()
        scan = receive(process, 5)
        report = json.loads(scan["result"]["content"][0]["text"])
        assert report["errorCount"] == 1, "Decoder timeout was not reported"
        assert time.monotonic() - started < 4
        send(process, request(6, "ping"))
        assert receive(process).get("id") == 6
    finally:
        stop(process)


def test_startup_recovery(root):
    blocked = root / "blocked"
    blocked.write_text("not a directory")
    settings = {"codexSessionsPath": str(root / "missing"), "dshSessionsPath": str(root / "missing-dsh"), "cursorUserPath": str(root / "missing-cursor"), "antigravityPath": str(root / "missing-antigravity"), "claudeProjectsPath": str(root / "missing-claude"), "databasePath": str(blocked / "db.sqlite")}
    process = spawn(root, settings)
    try:
        send(process, request(1, "initialize", {"protocolVersion": "2025-06-18"}))
        assert receive(process).get("id") == 1
        send(process, request(2, "tools/list"))
        assert receive(process).get("id") == 2
        send(process, request(3, "tools/call", {"name": "memory_list_projects", "arguments": {}}))
        failure = receive(process)
        assert failure["result"]["isError"] is True
        assert str(root) not in json.dumps(failure), "Error disclosed a local path"
        blocked.unlink(); blocked.mkdir()
        send(process, request(4, "tools/call", {"name": "memory_list_projects", "arguments": {}}))
        recovered = receive(process)
        assert not recovered["result"].get("isError", False), "Service did not recover after the fault was removed"
    finally:
        stop(process)


def test_atomic_binary_replacement(root):
    executable = root / "helper"
    shutil.copy2(HELPER, executable)
    settings = {"codexSessionsPath": str(root / "missing"), "dshSessionsPath": str(root / "missing-dsh"), "cursorUserPath": str(root / "missing-cursor"), "antigravityPath": str(root / "missing-antigravity"), "claudeProjectsPath": str(root / "missing-claude"), "databasePath": str(root / "db.sqlite")}
    settings_path = root / "settings.json"
    settings_path.write_text(json.dumps(settings))
    process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(os.environ, CONTEXTWEAVE_SETTINGS=str(settings_path)), bufsize=0)
    try:
        send(process, request(1, "initialize", {"protocolVersion": "2025-06-18"}))
        assert receive(process).get("id") == 1
        replacement = root / "helper-new"
        shutil.copy2(HELPER, replacement)
        os.replace(replacement, executable)
        notification = receive(process, 8)
        assert notification.get("method") == "notifications/tools/list_changed", "Replaced binary did not reinitialize the tool list"
        send(process, request(2, "ping"))
        assert receive(process).get("id") == 2, "Existing stdio connection did not survive replacement"
    finally:
        stop(process)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="contextweave-mcp-faults-") as tmp:
        root = Path(tmp)
        (root / "slow").mkdir(); test_blocked_scan(root / "slow")
        (root / "recovery").mkdir(); test_startup_recovery(root / "recovery")
        (root / "replacement").mkdir(); test_atomic_binary_replacement(root / "replacement")
    print("MCP stdio fault-injection checks passed")
