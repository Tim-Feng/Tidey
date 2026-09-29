#!/usr/bin/env python3
"""Ask the newly installed production Tidey to create the candidate-owned Runtime server.

usage: prepare_candidate_server.py --output <json> [--dry-run]

Gates before the call: production executable hash == candidate, Tidey socket responsive,
candidate socket absent, outgoing server unchanged. Requires prepared/created=true, a
fresh positive server_pid, the exact configured socket path and the canary session.
"""
import argparse
import json
from pathlib import Path

import deploy_common as dc


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    dc.configure_file(args.config)
    OUT = Path(args.output)
    if args.dry_run:
        # dry-runs never occupy the real evidence name
        OUT = OUT.with_name(OUT.name[:-5] + ".dryrun.json" if OUT.name.endswith(".json") else OUT.name + ".dryrun.json")
    if OUT.exists() or OUT.is_symlink():
        dc.fail(f"output occupied: {OUT}")
    CFG = dc.CFG

    if dc.sha256(dc.PRODUCTION / "Contents/MacOS/Tidey") != CFG["candidate_hashes"]["tidey"]:
        dc.fail("production executable is not the signed candidate; do not create a server from the outgoing build")
    tidey_pids = dc.exact_command_pids("/Applications/Tidey.app/Contents/MacOS/Tidey")
    if len(tidey_pids) != 1:
        dc.fail(f"expected one production Tidey process, got {tidey_pids}")
    if dc.CANDIDATE_SOCKET.exists() or dc.CANDIDATE_SOCKET.is_symlink():
        dc.fail(f"candidate socket already exists: {dc.CANDIDATE_SOCKET}")
    if dc.tmux_server_pid(dc.OUTGOING_SOCKET) != CFG["outgoing_tmux_pid"]:
        dc.fail("outgoing server PID changed")
    if Path(CFG["default_socket"]).exists():
        dc.fail("default tmux socket unexpectedly exists")
    _ = dc.request("list_workspaces")
    entries_before = sorted(str(p) for p in (dc.SUPPORT / "Runtime").glob("tmux-*.sock"))
    if entries_before != [str(dc.OUTGOING_SOCKET)]:
        dc.fail(f"Runtime socket union before preparation: {entries_before}")

    if args.dry_run:
        dc.write_json(OUT, {"dry_run": True, "server_id": CFG["candidate_server_id"], "candidate_socket": str(dc.CANDIDATE_SOCKET),
                            "production_tidey_pid": tidey_pids[0], "runtime_entries_before": entries_before})
        print("dry_run=validated-no-mutation")
        raise SystemExit(0)

    response = dc.request("prepare_isolated_tmux_server", {"server_id": CFG["candidate_server_id"]}, request_id_prefix="push-prepare")
    result = response["result"]
    problems = []
    if result.get("prepared") is not True or result.get("created") is not True:
        problems.append(f"prepared/created not true: {result!r}")
    if result.get("socket_path") != str(dc.CANDIDATE_SOCKET):
        problems.append(f"socket_path {result.get('socket_path')!r} != configured")
    if result.get("canary_session") != "tidey-runtime-canary":
        problems.append(f"canary_session {result.get('canary_session')!r}")
    server_pid = result.get("server_pid")
    if not isinstance(server_pid, int) or server_pid <= 0 or not dc.process_alive(server_pid):
        problems.append(f"server_pid invalid: {server_pid!r}")
    observed_pid = dc.tmux_server_pid(dc.CANDIDATE_SOCKET)
    if observed_pid != server_pid:
        problems.append(f"socket-resolved PID {observed_pid} != reported {server_pid}")
    if observed_pid == CFG["outgoing_tmux_pid"]:
        problems.append("candidate socket resolves to the outgoing server")
    command = dc.process_command(server_pid) or ""
    if str(dc.CANDIDATE_SOCKET) not in command:
        problems.append(f"server command does not reference candidate socket: {command!r}")
    entries_after = sorted(str(p) for p in (dc.SUPPORT / "Runtime").glob("tmux-*.sock"))
    if entries_after != sorted([str(dc.OUTGOING_SOCKET), str(dc.CANDIDATE_SOCKET)]):
        problems.append(f"Runtime socket union after preparation: {entries_after}")
    if dc.tmux_server_pid(dc.OUTGOING_SOCKET) != CFG["outgoing_tmux_pid"]:
        problems.append("outgoing server changed during preparation")
    payload = {"dry_run": False, "response": response, "observed_server_pid": observed_pid, "server_command": command,
               "runtime_entries_after": entries_after, "problems": problems}
    dc.write_json(OUT, payload)
    if problems:
        dc.fail("candidate server preparation gate failed: " + "; ".join(problems))
    print(json.dumps({"created": True, "server_pid": server_pid, "socket": str(dc.CANDIDATE_SOCKET)}))


if __name__ == "__main__":
    main()
