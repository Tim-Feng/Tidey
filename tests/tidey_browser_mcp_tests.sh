#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_UNDER_TEST="$SCRIPT_DIR/../Resources/bin/tidey-browser-mcp"

python3 - "$MCP_UNDER_TEST" <<'PY'
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading

mcp_path = Path(sys.argv[1]).resolve()


def send(process, message):
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()
    line = process.stdout.readline()
    if not line:
        raise AssertionError(f"MCP process exited early: {process.stderr.read()}")
    return json.loads(line)


with tempfile.TemporaryDirectory(prefix="tidey-browser-mcp-tests.") as temp_dir:
    socket_path = str(Path(temp_dir) / "tidey.sock")
    received = []
    ready = threading.Event()

    def serve():
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(socket_path)
        server.listen(1)
        ready.set()
        connection, _ = server.accept()
        with connection, connection.makefile("rb") as reader:
            for raw_line in reader:
                request = json.loads(raw_line)
                received.append(request)
                if request["params"]["operation"] == "open":
                    response = {"id": request["id"], "ok": True,
                                "result": {"tab_id": "private-1", "private": True}}
                else:
                    response = {"id": request["id"], "ok": False,
                                "error": {"code": "ownership_conflict", "message": "Owned elsewhere"}}
                connection.sendall(json.dumps(response).encode() + b"\n")
        server.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    if not ready.wait(2):
        raise AssertionError("fake Tidey socket did not start")

    environment = dict(os.environ)
    environment.update({"TIDEY_SOCKET_PATH": socket_path, "TIDEY_WORKSPACE_ID": "workspace-7"})
    process = subprocess.Popen(
        [str(mcp_path)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
    )
    try:
        initialized = send(process, {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": "test", "version": "1"}},
        })
        assert initialized["result"]["protocolVersion"] == "2025-06-18"
        assert initialized["result"]["capabilities"]["tools"]["listChanged"] is False
        assert "private and hidden" in initialized["result"]["instructions"]

        tools = send(process, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        names = {item["name"] for item in tools["result"]["tools"]}
        expected = {"tabs", "open", "claim", "release", "reclaim", "mark", "close", "present",
                    "navigate", "back", "forward", "reload", "current_url", "snapshot", "click",
                    "fill", "type", "key", "scroll", "wait", "screenshot", "transfer_start",
                    "transfer_status", "transfer_pause"}
        assert names == expected
        tabs = next(item for item in tools["result"]["tools"] if item["name"] == "tabs")
        assert "agent session" in tabs["description"]
        assert all("Codex" not in item["description"] for item in tools["result"]["tools"])
        assert all(item["inputSchema"].get("additionalProperties") is False
                   for item in tools["result"]["tools"])
        transfer_start = next(item for item in tools["result"]["tools"]
                              if item["name"] == "transfer_start")
        assert "expected_total_bytes" in transfer_start["inputSchema"]["required"]
        assert transfer_start["inputSchema"]["properties"]["expected_total_bytes"]["minimum"] == 1

        opened = send(process, {
            "jsonrpc": "2.0", "id": "call-1", "method": "tools/call",
            "params": {"name": "open", "arguments": {"url": "https://example.com/"}},
        })
        assert opened["result"]["structuredContent"] == {"tab_id": "private-1", "private": True}
        assert opened["result"].get("isError") is None

        conflict = send(process, {
            "jsonrpc": "2.0", "id": "call-2", "method": "tools/call",
            "params": {"name": "claim", "arguments": {"tab_id": "visible-1"}},
        })
        assert conflict["result"]["isError"] is True
        assert json.loads(conflict["result"]["content"][0]["text"])["code"] == "ownership_conflict"

        unknown = send(process, {
            "jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": {"name": "evaluate_javascript", "arguments": {}},
        })
        assert unknown["error"]["code"] == -32602
    finally:
        process.stdin.close()
        process.wait(timeout=3)

    assert len(received) == 2
    assert all(item["action"] == "browser_automation" for item in received)
    assert all(item["params"]["workspace_id"] == "workspace-7" for item in received)
    assert received[0]["params"]["operation"] == "open"
    assert received[0]["params"]["parameters"] == {"url": "https://example.com/"}

missing_environment = subprocess.run(
    [str(mcp_path)],
    input=json.dumps({"jsonrpc": "2.0", "id": 8, "method": "tools/call",
                      "params": {"name": "tabs", "arguments": {}}}) + "\n",
    text=True,
    capture_output=True,
    env={key: value for key, value in os.environ.items()
         if key not in {"TIDEY_SOCKET_PATH", "TIDEY_WORKSPACE_ID"}},
    check=True,
)
failure = json.loads(missing_environment.stdout)
assert failure["result"]["isError"] is True
assert "TIDEY_SOCKET_PATH is required" in failure["result"]["content"][0]["text"]

print("tidey_browser_mcp_tests: PASS")
PY
