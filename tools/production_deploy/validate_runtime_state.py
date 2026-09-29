#!/usr/bin/env python3
"""Baseline-relative identity/topology/registry validator.

usage: validate_runtime_state.py <mode> --checkpoint <baseline-dir> [--output <json>]

modes (N = baseline tmux registry count; every count is baseline-relative; native writers are
checked separately against the iTermServer generation of the mode, see registry_gate):
  preinstall               outgoing build; all descriptors/registries on outgoing; N writers
  installed-pre-new-server candidate installed+launched (fresh PIDs); all on outgoing; N
  new-server-pre-stage     candidate socket live, nothing staged; N
  phase1-pre               B descriptor on candidate; B writer exited (N-1, all outgoing)
  phase1-post              B restored on candidate (N: N-1 outgoing + 1 candidate)
  phase2-pre               every descriptor on candidate; only B live, on candidate (1)
  phase2-post              every descriptor on candidate; N writers all on candidate; outgoing
                           server contains only shells
  post-retirement          outgoing socket gone; N writers on candidate; LaunchServices clean;
                           archive holders zero
Every mode also proves: process ancestry of every registry writer lands in its advertised pane
on its advertised socket; session/window topology matches the descriptors; the decoded
SavedState graph equals the live workspace/panel/descriptor identities; the process serving
tidey.sock is the expected build (executable hash, not path); Bridge/Cloudflare healthy.
"""
import argparse
import json
from collections import Counter
from pathlib import Path

import deploy_common as dc

MODES = ["preinstall", "installed-pre-new-server", "new-server-pre-stage", "phase1-pre", "phase1-post",
         "phase2-pre", "phase2-post", "post-retirement"]

def registry_gate(MODE, baseline, baseline_registries, summary, snapshot, registries, table, daemon_pid, B):
    """Identity, descriptor and registry expectations for one mode. Pure over its inputs apart
    from dc.process_start, so fixtures drive the same code main runs."""
    problems = []
    B_KEY, B_SESSION = (B["vendor"], B["durable_id"]), B["session"]
    OUT_S, CAND_S = str(dc.OUTGOING_SOCKET), str(dc.CANDIDATE_SOCKET)
    base_ws, base_panels, base_by_session = dc.identity_sets(baseline)
    base_tmux = [r for r in baseline_registries if r.get("tmux_socket_path") and r.get("tmux_pane_id")]
    base_durable = set(dc.durable_keys(base_tmux))
    N = len(base_tmux)
    stored = summary.get("native_writers")
    base_native = {(w["vendor"], w["durable_id"]): w for w in stored} if isinstance(stored, list) else None

    cur_ws, cur_panels, cur_by_session = dc.identity_sets(snapshot)
    if cur_ws != base_ws or cur_panels != base_panels:
        problems.append(f"workspace/panel identity differs from baseline: ws {len(cur_ws)}/{len(base_ws)} panels {len(cur_panels)}/{len(base_panels)}")
    if set(cur_by_session) != set(base_by_session):
        problems.append(f"descriptor session set differs: {sorted(set(cur_by_session) ^ set(base_by_session))}")
    problems.extend(dc.native_descriptor_problems(baseline, snapshot))
    candidate_sessions = set()
    if MODE in {"phase1-pre", "phase1-post"}:
        candidate_sessions = {B_SESSION}
    elif MODE in {"phase2-pre", "phase2-post", "post-retirement"}:
        candidate_sessions = set(base_by_session)
    for session, base_item in base_by_session.items():
        cur = cur_by_session.get(session)
        if not cur:
            continue
        expected = json.loads(json.dumps(base_item["descriptor"]))
        expected["target"]["socket_path"] = CAND_S if session in candidate_sessions else OUT_S
        if cur["descriptor"] != expected:
            problems.append(f"descriptor semantic drift for {session}")
        for key in ("workspace_id", "panel_id"):
            if cur["binding"].get(key) != base_item["binding"].get(key):
                problems.append(f"{key} binding drift for {session}")
        pane_may_change = (MODE in {"phase1-post", "phase2-pre"} and session == B_SESSION) or MODE in {"phase2-post", "post-retirement"}
        if not pane_may_change and cur["binding"].get("tmux_pane_id") != base_item["binding"].get("tmux_pane_id"):
            problems.append(f"pane binding drift for {session}: {cur['binding'].get('tmux_pane_id')} vs {base_item['binding'].get('tmux_pane_id')}")
        if pane_may_change and not str(cur["binding"].get("tmux_pane_id", "")).startswith("%"):
            problems.append(f"missing restored pane evidence for {session}")
        if cur.get("revision", 0) < base_item.get("revision", 0):
            problems.append(f"descriptor revision regressed for {session}")

    for item in registries:
        if not item["live_fields"].get("pid") or any(not alive for alive in item["live_fields"].values()):
            problems.append(f"dead registry writer or child: {item['path']}")
    keys = dc.durable_keys(registries)
    if len(keys) != len(set(keys)):
        problems.append("duplicate live durable writer")
    panel_dups = [p for p, c in Counter(item["panel_id"] for item in registries).items() if c > 1]
    if panel_dups:
        problems.append(f"two registry writers on one panel: {panel_dups}")
    tmux_records, native, native_problems = dc.classify_registries(registries, snapshot, table, daemon_pid)
    problems.extend(native_problems)
    for writer in native.values():
        writer["start"] = dc.process_start(writer["pid"])
    daemon_start = dc.process_start(daemon_pid) if daemon_pid else None
    problems.extend(dc.native_generation_problems(dc.native_generation_for(MODE), native, base_native, daemon_start))

    if MODE in {"preinstall", "installed-pre-new-server", "new-server-pre-stage"}:
        expected_split, expected_durable = Counter({OUT_S: N}), base_durable
    elif MODE == "phase1-pre":
        expected_split, expected_durable = Counter({OUT_S: N - 1}), base_durable - {B_KEY}
    elif MODE == "phase1-post":
        expected_split, expected_durable = Counter({OUT_S: N - 1, CAND_S: 1}), base_durable
    elif MODE == "phase2-pre":
        expected_split, expected_durable = Counter({CAND_S: 1}), {B_KEY}
    else:
        expected_split, expected_durable = Counter({CAND_S: N}), base_durable
    # tmux split counts only tmux writers; durable coverage also keeps every baseline native
    # (the lineage handoff never asks a native writer to exit).
    actual_split = Counter(item["tmux_socket_path"] for item in tmux_records)
    if actual_split != expected_split:
        problems.append(f"registry socket split {dict(actual_split)} != expected {dict(expected_split)}")
    expected_all = expected_durable | set(base_native or ())
    current_all = {(r["vendor"], r["durable_id"]) for r in tmux_records} | set(native)
    if current_all != expected_all:
        problems.append(f"durable set differs: missing {sorted(expected_all - current_all)} extra {sorted(current_all - expected_all)}")
    if MODE in {"phase1-post", "phase2-pre", "phase2-post", "post-retirement"}:
        b_matches = [item for item in tmux_records if (item["vendor"], item["durable_id"]) == B_KEY]
        if len(b_matches) != 1 or b_matches[0]["tmux_socket_path"] != CAND_S:
            problems.append("controller B is not the unique candidate-owned writer")
    return {"problems": problems, "workspace_ids": cur_ws, "panel_ids": cur_panels, "by_session": cur_by_session,
            "keys": keys, "actual_split": actual_split, "N": N, "tmux": tmux_records,
            "native": [{"vendor": k[0], "durable_id": k[1], **v} for k, v in sorted(native.items())]}


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("mode", choices=MODES)
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--output")
    args = parser.parse_args(argv)
    dc.configure_file(args.config)
    MODE = args.mode
    CFG = dc.CFG
    B = CFG["controllers"]["b"]
    B_SESSION = B["session"]
    OUT_S, CAND_S = str(dc.OUTGOING_SOCKET), str(dc.CANDIDATE_SOCKET)
    problems = []

    baseline, baseline_registries, summary = dc.load_checkpoint(args.checkpoint)
    if summary.get("kind") != "predeploy":
        dc.fail("--checkpoint must be the predeploy baseline")
    base_ws, base_panels, base_by_session = dc.identity_sets(baseline)
    if len(set(dc.durable_keys(baseline_registries))) != len(baseline_registries):
        dc.fail("baseline registry has duplicate durable keys; refuse to validate against it")
    base_tidey_pid = summary["service_pids"]["tidey"]

    # --- build identity: file hashes and the process actually serving the socket ---
    expected_hashes = CFG["outgoing_hashes"] if MODE == "preinstall" else CFG["candidate_hashes"]
    observed = {
        "tidey": dc.sha256(dc.PRODUCTION / "Contents/MacOS/Tidey"),
        "itermserver": dc.sha256(dc.PRODUCTION / "Contents/MacOS/iTermServer"),
        "bridge": dc.sha256(dc.PRODUCTION / "Contents/Resources/RemoteBridge/tidey-remote-bridge"),
    }
    if observed != expected_hashes:
        problems.append(f"production bundle hashes {observed} != expected for {MODE}")
    if dc.sha256(dc.BRIDGE_SUPPORT / "tidey-remote-bridge") != expected_hashes["bridge"]:
        problems.append("installed Bridge hash != expected")
    if dc.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(dc.PRODUCTION)])[0]:
        problems.append("production signature verification failed")
    try:
        socket_pid, socket_exe = dc.tidey_socket_server()
        if socket_exe != str(dc.PRODUCTION / "Contents/MacOS/Tidey") or dc.sha256(socket_exe) != expected_hashes["tidey"]:
            problems.append(f"tidey.sock served by {socket_pid} {socket_exe} whose hash is not the expected build")
        if MODE != "preinstall" and socket_pid == base_tidey_pid:
            problems.append("tidey.sock still served by the baseline Tidey PID; no fresh process")
    except dc.GateError as error:
        socket_pid, socket_exe = None, None
        problems.append(str(error))
    table = dc.process_table()
    tidey_pids = dc.exact_command_pids(str(dc.PRODUCTION / "Contents/MacOS/Tidey"), table)
    if len(tidey_pids) != 1 or tidey_pids[0] != socket_pid:
        problems.append(f"production Tidey processes {tidey_pids} vs socket server {socket_pid}")
    # --- exact iTermServer lifecycle (attach vs fresh daemon; see dc.itermserver_phase_problems) ---
    iterm_observed = dc.observe_itermserver(table)
    iterm_pids = iterm_observed["daemon_pids"]
    if len(iterm_pids) != 1:
        problems.append(f"iTermServer processes {iterm_pids}")
    else:
        iterm_baseline = {
            "pid": summary["service_pids"]["itermserver"],
            "command": summary.get("hashes", {}) and json.loads((Path(args.checkpoint) / "service-pids.json").read_text(encoding="utf-8"))["commands"]["itermserver"],
            "support_hash": summary["hashes"]["production"]["installed_itermserver"],
        }
        problems.extend(dc.itermserver_phase_problems(MODE, iterm_observed, iterm_baseline,
                                                      CFG["outgoing_hashes"]["itermserver"], CFG["candidate_hashes"]["itermserver"]))

    # --- workspace/panel/descriptor identity and registry vs baseline ---
    snapshot = dc.socket_snapshot()
    registries = dc.registry_inventory()
    gate = registry_gate(MODE, baseline, baseline_registries, summary, snapshot, registries, table,
                         iterm_observed["daemon_pid"], B)
    problems.extend(gate["problems"])
    cur_ws, cur_panels, cur_by_session = gate["workspace_ids"], gate["panel_ids"], gate["by_session"]
    keys, actual_split, N = gate["keys"], gate["actual_split"], gate["N"]
    problems.extend(dc.saved_state_matches(snapshot))
    topology, topology_problems = dc.registry_topology(gate["tmux"], table)
    problems.extend(topology_problems)

    # --- tmux topology vs descriptors on each live server ---
    outgoing_pid = dc.tmux_server_pid(dc.OUTGOING_SOCKET) if dc.OUTGOING_SOCKET.exists() else None
    candidate_pid = dc.tmux_server_pid(dc.CANDIDATE_SOCKET) if dc.CANDIDATE_SOCKET.exists() else None
    if MODE == "post-retirement":
        if dc.OUTGOING_SOCKET.exists() or outgoing_pid or dc.process_alive(CFG["outgoing_tmux_pid"]):
            problems.append("outgoing server or socket still present after retirement")
    else:
        if outgoing_pid != CFG["outgoing_tmux_pid"]:
            problems.append(f"outgoing server PID {outgoing_pid} != {CFG['outgoing_tmux_pid']}")
    if MODE in {"preinstall", "installed-pre-new-server"}:
        if dc.CANDIDATE_SOCKET.exists():
            problems.append("candidate socket exists too early")
    else:
        if not candidate_pid or candidate_pid == outgoing_pid:
            problems.append("candidate server not live or same as outgoing")
    runtime_entries = sorted(str(p) for p in (dc.SUPPORT / "Runtime").glob("tmux-*.sock"))
    expected_entries = sorted(([OUT_S] if MODE != "post-retirement" else []) + ([CAND_S] if candidate_pid else []))
    if runtime_entries != expected_entries:
        problems.append(f"Runtime socket union {runtime_entries} != {expected_entries}")
    if Path(CFG["default_socket"]).exists():
        problems.append("default tmux socket unexpectedly exists")

    pane_maps = {}
    for label, sock, pid in (("outgoing", dc.OUTGOING_SOCKET, outgoing_pid), ("candidate", dc.CANDIDATE_SOCKET, candidate_pid)):
        if pid:
            pane_maps[str(sock)] = dc.tmux_pane_map(sock)
    for session, cur in cur_by_session.items():
        sock = cur["descriptor"]["target"]["socket_path"]
        panes = pane_maps.get(sock, {})
        session_panes = {p: i for p, i in panes.items() if i["session"] == session}
        binding_pane = cur["binding"].get("tmux_pane_id")
        expects_live_session = (
            MODE in {"preinstall", "installed-pre-new-server", "new-server-pre-stage"}
            or (MODE in {"phase1-pre"} and session != B_SESSION)
            or MODE in {"phase1-post"}
            or (MODE == "phase2-pre" and session == B_SESSION)
            or MODE in {"phase2-post", "post-retirement"}
        )
        if not expects_live_session:
            continue
        if not session_panes:
            problems.append(f"descriptor {session} targets {sock[-36:]} but no such session exists there")
            continue
        if binding_pane not in session_panes:
            problems.append(f"descriptor {session} binding pane {binding_pane} is not a pane of that session on its socket")
        windows = cur["descriptor"]["topology"].get("windows", [])
        live_names = sorted(i["window_name"] for i in session_panes.values())
        if len(windows) > 1 and sorted(w.get("name") for w in windows) != live_names:
            problems.append(f"window topology for {session} differs: descriptor {sorted(w.get('name') for w in windows)} live {live_names}")
        # the writer for this session must sit in a pane of this session on this socket
        launches = [p.get("launch", {}).get("arguments", []) for w in windows for p in w.get("panes", [])]
        durables = {a[-1] for a in launches if a}
        writers = [r for r in registries if r["durable_id"] in durables]
        for r in writers:
            actual = dc.pane_of_pid(r["pid"], panes, table) if r["pid"] in table else None
            if actual not in session_panes:
                problems.append(f"writer {r['durable_id'][:8]} for {session} is not inside that session on {sock[-36:]} (pane {actual})")

    # --- outgoing server content at the end of the handoff ---
    if MODE == "phase2-post":
        panes = pane_maps.get(OUT_S, {})
        for pane_id, info in panes.items():
            if info["command"] not in {"zsh", "bash"} or dc.descendants(info["pane_pid"], table):
                problems.append(f"outgoing pane {pane_id} ({info['session']}) is not an empty shell")
        base_outgoing = json.loads((Path(args.checkpoint) / "tmux-pane-processes-outgoing.json").read_text(encoding="utf-8"))
        old_pids = {pid for info in base_outgoing.values() for pid in info.get("descendants", [])}
        alive_old, reused_old = dc.original_live_pids(old_pids, summary["captured_at"])
        if alive_old:
            problems.append(f"baseline outgoing writer subtree members still alive: {sorted(alive_old)[:12]}")

    # --- archives, LaunchServices (post-retirement only) ---
    if MODE == "post-retirement":
        ls_problems, ls_facts = dc.ls_gate()
        problems.extend(ls_problems)
        holders = []
        for archive_dir in sorted(dc.ARCHIVE_ROOT.glob("*.bundle-archive")):
            holders.extend(dc.lsof_holders(archive_dir))
        if holders or dc.argv_holders(dc.ARCHIVE_ROOT, table):
            problems.append("deployment archive holders remain after retirement")
        if not dc.ARCHIVE.is_dir():
            problems.append(f"retained archive missing: {dc.ARCHIVE}")

    # --- databases and services ---
    for database in (dc.SUPPORT / "SavedState/restorable-state.sqlite", dc.SUPPORT / "chatdb.sqlite", dc.SUPPORT / "Tidey.sqlite"):
        if dc.quick_check(database) != "ok":
            problems.append(f"quick_check failed: {database}")
    try:
        bridge_http, bridge = dc.bridge_admin_status()
        if bridge_http != 200:
            problems.append(f"Bridge HTTP {bridge_http}")
    except Exception as error:  # noqa: BLE001
        bridge = {}
        problems.append(f"Bridge admin status error: {error}")
    cloudflare = dc.cloudflare_state()
    if cloudflare.get("state") != "online" or not dc.process_alive(cloudflare.get("process_id")):
        problems.append(f"Cloudflare unhealthy: {cloudflare!r}")

    result = {
        "mode": MODE, "checkpoint": args.checkpoint, "problems": problems,
        "workspace_count": len(cur_ws), "panel_count": len(cur_panels), "descriptor_count": len(cur_by_session),
        "descriptor_socket_split": dict(Counter(item["descriptor"]["target"]["socket_path"] for item in cur_by_session.values())),
        "registry_count": len(registries), "registry_socket_split": dict(actual_split), "unique_durable_count": len(set(keys)),
        "baseline_registry_count": N, "outgoing_tmux_pid": outgoing_pid, "candidate_tmux_pid": candidate_pid,
        "production_tidey_pid": tidey_pids[0] if len(tidey_pids) == 1 else None, "tidey_socket_server_pid": socket_pid,
        "itermserver_pid": iterm_pids[0] if len(iterm_pids) == 1 else None,
        "itermserver_support_hash": iterm_observed["support_hash"],
        "registry_topology": topology, "native_writers": gate["native"],
        "bridge_active_session_count": len(bridge.get("active_sessions", [])) if isinstance(bridge.get("active_sessions"), list) else None,
        "cloudflared_pid": cloudflare.get("process_id"),
    }
    if args.output:
        dc.write_json(args.output, result)
    print(json.dumps({k: v for k, v in result.items() if k != "registry_topology"}, ensure_ascii=False, sort_keys=True))
    if problems:
        dc.fail(f"{len(problems)} gate problem(s) in mode {MODE}")


if __name__ == "__main__":
    main()
