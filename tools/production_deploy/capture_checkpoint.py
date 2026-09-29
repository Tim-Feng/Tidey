#!/usr/bin/env python3
"""Create one consistent, uniquely named checkpoint of live production state.

usage: capture_checkpoint.py <checkpoint-leaf> --kind <kind> [--baseline <dir>] [--root <dir>]

kinds and what they require (see PHASES.md):
  predeploy        outgoing build installed; zero holders under every retained archive; both
                   controllers live; every descriptor/registry on the outgoing socket.
  b-only           after install + candidate server + B descriptor staged, BEFORE B exits.
                   --baseline required: N writers (all outgoing), both controllers live, B's
                   descriptor on the candidate socket, holders under the NEW archive are a
                   subset of the baseline wrapper set, ZERO holders under every older archive.
  all-descriptors  after phase-1 restart + all descriptors staged, BEFORE any other writer
                   exits. --baseline required: N writers (B on candidate, N-1 outgoing), every
                   descriptor on the candidate socket, same archive holder rule.
  phase            after A exited, before the phase-2 restart. --baseline required: exactly B
                   live (on candidate), every descriptor on candidate, descriptor session set
                   and workspace/panel identity equal to the baseline, same archive rule.
N counts tmux writers only. Native writers (no tmux transport) are proven by ancestry under the
current iTermServer and tied to its generation; durable coverage always includes every baseline
native writer (see registry_gate). Controllers must be tmux writers.
Writes only under <root>/<leaf>; refuses an occupied target. Counts are recorded, not
asserted from literals: the baseline checkpoint is the reference.
"""
import argparse
import datetime as dt
import hashlib
import json
import shutil
from collections import Counter
from pathlib import Path

import deploy_common as dc


# Native writers follow the iTermServer generation of each checkpoint kind: b-only is still
# the baseline daemon; all-descriptors and phase come after the phase-1 restart.
CAPTURE_GENERATION = {"predeploy": "baseline", "b-only": "attach", "all-descriptors": "fresh", "phase": "fresh"}


def registry_gate(kind, snapshot, registries, table, daemon_pid, baseline, controller_specs, OUT_S, CAND_S):
    """Registry/descriptor/controller identity gate. Pure over its inputs apart from
    dc.process_start, so fixtures drive the same code main runs."""
    problems = []
    workspace_ids, panel_ids, by_session = dc.identity_sets(snapshot)
    descriptor_split = Counter(item["descriptor"]["target"]["socket_path"] for item in by_session.values())
    keys = dc.durable_keys(registries)
    if len(keys) != len(set(keys)):
        problems.append("duplicate durable writer in registry")
    dup_panels = [panel for panel, count in Counter(item["panel_id"] for item in registries).items() if count > 1]
    if dup_panels:
        problems.append(f"more than one registry record on one panel: {dup_panels}")
    for item in registries:
        if not item["live_fields"].get("pid") or any(not alive for alive in item["live_fields"].values()):
            problems.append(f"dead registry writer: {item['path']}")
    tmux_records, native, native_problems = dc.classify_registries(registries, snapshot, table, daemon_pid)
    problems.extend(native_problems)
    for writer in native.values():
        writer["start"] = dc.process_start(writer["pid"])
    daemon_start = dc.process_start(daemon_pid) if daemon_pid else None
    base_native = None
    if baseline:
        stored = baseline[2].get("native_writers")
        base_native = {(w["vendor"], w["durable_id"]): w for w in stored} if isinstance(stored, list) else None
    problems.extend(dc.native_generation_problems(CAPTURE_GENERATION[kind], native, base_native, daemon_start))
    tmux_keys = {(item["vendor"], item["durable_id"]) for item in tmux_records}

    if baseline:
        base_ws, base_panels, base_by_session = dc.identity_sets(baseline[0])
        base_tmux = [r for r in baseline[1] if r.get("tmux_socket_path") and r.get("tmux_pane_id")]
        base_keys = set(dc.durable_keys(base_tmux))
        base_native_keys = set(base_native or ())
        N = len(base_tmux)
        if workspace_ids != base_ws or panel_ids != base_panels:
            problems.append("workspace/panel identity differs from baseline")
        if set(by_session) != set(base_by_session):
            problems.append("descriptor session set differs from baseline")
        problems.extend(dc.native_descriptor_problems(baseline[0], snapshot))
        B = controller_specs["b"]
        if kind == "b-only":
            exp_split, exp_keys = Counter({OUT_S: N}), base_keys
            exp_desc = {s: (CAND_S if s == B["session"] else OUT_S) for s in base_by_session}
        elif kind == "all-descriptors":
            exp_split, exp_keys = Counter({OUT_S: N - 1, CAND_S: 1}), base_keys
            exp_desc = {s: CAND_S for s in base_by_session}
        else:  # phase (after A exited)
            exp_split, exp_keys = Counter({CAND_S: 1}), {(B["vendor"], B["durable_id"])}
            exp_desc = {s: CAND_S for s in base_by_session}
        # tmux split counts only tmux writers; durable coverage also keeps every baseline native.
        actual_split = Counter(item["tmux_socket_path"] for item in tmux_records)
        if actual_split != exp_split:
            problems.append(f"registry socket split {dict(actual_split)} != expected {dict(exp_split)} for kind {kind}")
        exp_all, cur_all = exp_keys | base_native_keys, tmux_keys | set(native)
        if cur_all != exp_all:
            problems.append(f"durable set differs for kind {kind}: missing {sorted(exp_all - cur_all)} extra {sorted(cur_all - exp_all)}")
        for session, sock in exp_desc.items():
            cur = by_session.get(session)
            if cur and cur["descriptor"]["target"]["socket_path"] != sock:
                problems.append(f"descriptor {session} on {cur['descriptor']['target']['socket_path'][-40:]}, expected {sock[-40:]}")
    else:
        if descriptor_split != Counter({OUT_S: len(by_session)}):
            problems.append("not every tmux descriptor targets the outgoing socket")
        if any(item["tmux_socket_path"] != OUT_S for item in tmux_records):
            problems.append("registry writer outside the outgoing socket")

    # --- controllers: tmux only (they must survive iTermServer restarts on a tmux server) ---
    controllers = {}
    required_controllers = ("a", "b") if kind != "phase" else ("b",)
    for role in ("a", "b"):
        spec = controller_specs[role]
        spec_key = (spec["vendor"], spec["durable_id"])
        if spec_key in native:
            problems.append(f"unsupported_native_controller: controller {role} {spec_key} is a native writer")
        item = by_session.get(spec["session"])
        if not item:
            problems.append(f"missing controller descriptor: {spec['session']}")
            continue
        binding = item["binding"]
        if (binding.get("workspace_id"), binding.get("panel_id")) != (spec["workspace_id"], spec["panel_id"]):
            problems.append(f"controller {role} workspace/panel binding drift")
        matches = [r for r in tmux_records if (r["vendor"], r["durable_id"]) == spec_key]
        if role in required_controllers and len(matches) != 1:
            problems.append(f"unsupported_deployment_contract: controller {role} needs exactly one live tmux writer, found {len(matches)}")
        if role == "a" and kind == "phase" and matches:
            problems.append("controller A still live in a phase checkpoint (A must have exited)")
        controllers[role] = {"spec": spec, "descriptor_revision": item["revision"], "binding": binding,
                             "registry": matches[0] if len(matches) == 1 else None}
    native_list = [{"vendor": k[0], "durable_id": k[1], **v} for k, v in sorted(native.items())]
    return {"problems": problems, "workspace_ids": workspace_ids, "panel_ids": panel_ids, "by_session": by_session,
            "descriptor_split": descriptor_split, "keys": keys, "tmux": tmux_records, "native": native_list,
            "daemon_start": daemon_start, "controllers": controllers}


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("leaf")
    parser.add_argument("--kind", required=True, choices=["predeploy", "b-only", "all-descriptors", "phase"])
    parser.add_argument("--baseline")
    parser.add_argument("--root")
    args = parser.parse_args(argv)
    dc.configure_file(args.config)

    if "/" in args.leaf or args.leaf in {"", ".", ".."}:
        dc.fail("checkpoint leaf must be a single path component")
    ROOT = dc.literal_dir(args.root or dc.CFG["checkpoint_root"], "checkpoint root")
    CHECKPOINT = ROOT / args.leaf
    if CHECKPOINT.exists() or CHECKPOINT.is_symlink():
        dc.fail(f"checkpoint target occupied: {CHECKPOINT}")
    post_install = args.kind != "predeploy"
    if post_install and not args.baseline:
        dc.fail(f"--baseline is required for kind {args.kind}")
    baseline = None
    if args.baseline:
        baseline = dc.load_checkpoint(args.baseline)
        if baseline[2].get("kind") != "predeploy":
            dc.fail("--baseline must point at the predeploy checkpoint")

    CFG = dc.CFG
    CANDIDATE = Path(CFG["candidate_app"])
    WORKTREE = Path(CFG["worktree"])
    problems = []

    for required in (dc.SUPPORT, dc.BRIDGE_SUPPORT, dc.PRODUCTION, CANDIDATE, WORKTREE, dc.ARCHIVE_ROOT):
        if not required.exists() or required.is_symlink():
            dc.fail(f"invalid required path: {required}")
    if not dc.SOCKET_API.is_socket():
        dc.fail("Tidey socket missing")
    if Path(CFG["default_socket"]).exists():
        dc.fail("default tmux socket unexpectedly exists")

    # --- production identity: which build is installed and which process serves the socket ---
    expected_hashes = CFG["candidate_hashes"] if post_install else CFG["outgoing_hashes"]
    production_hashes = {
        "tidey": dc.sha256(dc.PRODUCTION / "Contents/MacOS/Tidey"),
        "itermserver": dc.sha256(dc.PRODUCTION / "Contents/MacOS/iTermServer"),
        "bridge": dc.sha256(dc.PRODUCTION / "Contents/Resources/RemoteBridge/tidey-remote-bridge"),
    }
    if production_hashes != expected_hashes:
        problems.append(f"production hashes {production_hashes} != expected for kind {args.kind}")
    socket_pid, socket_exe = dc.tidey_socket_server()
    if socket_exe != str(dc.PRODUCTION / "Contents/MacOS/Tidey") or dc.sha256(socket_exe) != expected_hashes["tidey"]:
        problems.append(f"process serving tidey.sock is {socket_pid} {socket_exe}, not the expected build")
    if post_install and socket_pid == baseline[2]["service_pids"]["tidey"]:
        problems.append("tidey.sock is still served by the baseline (outgoing) Tidey PID")

    # --- Runtime servers ---
    runtime_entries = sorted((dc.SUPPORT / "Runtime").glob("tmux-*.sock"))
    expected_entries = [dc.OUTGOING_SOCKET] + ([dc.CANDIDATE_SOCKET] if post_install else [])
    if runtime_entries != sorted(expected_entries):
        problems.append(f"Runtime socket union {[str(p) for p in runtime_entries]} != {[str(p) for p in expected_entries]}")
    outgoing_pid = dc.tmux_server_pid(dc.OUTGOING_SOCKET)
    if outgoing_pid != CFG["outgoing_tmux_pid"]:
        problems.append(f"outgoing server PID {outgoing_pid} != configured {CFG['outgoing_tmux_pid']}")
    candidate_pid = dc.tmux_server_pid(dc.CANDIDATE_SOCKET) if dc.CANDIDATE_SOCKET.exists() else None
    if post_install and not candidate_pid:
        problems.append("candidate server not live")

    # --- Git identity of the feature worktree ---
    head = dc.run_out(["/usr/bin/git", "-C", str(WORKTREE), "rev-parse", "HEAD"], check=True)[1].strip()
    if head != CFG["expected_head"]:
        problems.append(f"worktree HEAD {head} != expected {CFG['expected_head']}")
    git_status = dc.run_out(["/usr/bin/git", "-C", str(WORKTREE), "status", "--porcelain=v2", "--branch"], check=True)[1]
    staged_diff = dc.run_out(["/usr/bin/git", "-C", str(WORKTREE), "diff", "--cached", "--binary"], check=True)[1]
    working_diff = dc.run_out(["/usr/bin/git", "-C", str(WORKTREE), "diff", "--binary"], check=True)[1]
    git_digest = hashlib.sha256((git_status + staged_diff + working_diff).encode("utf-8", "surrogateescape")).hexdigest()
    if baseline and git_digest != baseline[2]["worktree_identity_sha256"]:
        problems.append("worktree identity digest differs from the baseline checkpoint")

    # --- socket snapshot, descriptors, registry ---
    snapshot = dc.socket_snapshot()
    registries = dc.registry_inventory()
    table = dc.process_table()
    iterm_observed = dc.observe_itermserver(table)
    gate = registry_gate(args.kind, snapshot, registries, table, iterm_observed["daemon_pid"],
                         baseline, CFG["controllers"], str(dc.OUTGOING_SOCKET), str(dc.CANDIDATE_SOCKET))
    problems.extend(gate["problems"])
    workspace_ids, panel_ids, by_session = gate["workspace_ids"], gate["panel_ids"], gate["by_session"]
    descriptors = snapshot["runtime_resume_descriptors"]["result"]["descriptors"]
    descriptor_split, keys, controllers = gate["descriptor_split"], gate["keys"], gate["controllers"]
    topology, topology_problems = dc.registry_topology(gate["tmux"], table)
    problems.extend(topology_problems)
    saved_problems = dc.saved_state_matches(snapshot)
    problems.extend(saved_problems)

    # --- full pane inventory of every live Runtime server ---
    tmux_inventory = {}
    for label, sock in (("outgoing", dc.OUTGOING_SOCKET), ("candidate", dc.CANDIDATE_SOCKET)):
        if not sock.exists():
            continue
        sessions = dc.tmux(sock, "list-sessions", "-F", "#{session_name}|#{session_id}|#{session_created}|#{session_attached}|#{session_windows}")[1]
        panes = dc.tmux_pane_map(sock)
        captures, processes = {}, {}
        for pane_id, info in panes.items():
            captures[pane_id] = dc.tmux(sock, "capture-pane", "-p", "-t", pane_id, "-S", "-30")[1]
            kids = dc.descendants(info["pane_pid"], table)
            processes[pane_id] = {**info, "descendants": kids,
                                  "descendant_commands": {str(pid): table[pid][1][:300] for pid in kids if pid in table}}
        tmux_inventory[label] = {"sessions": sessions, "panes": panes, "captures": captures, "processes": processes}

    # --- services ---
    bridge_pid, bridge_launchd = dc.launchd_pid(CFG["bridge_labels"]["bridge"])
    supervisor_pid, supervisor_launchd = dc.launchd_pid(CFG["bridge_labels"]["supervisor"])
    cloudflare = dc.cloudflare_state()
    cloudflared_pid = cloudflare.get("process_id")
    if not (bridge_pid and supervisor_pid and cloudflare.get("state") == "online" and dc.process_alive(cloudflared_pid)):
        problems.append(f"Bridge/Cloudflare unhealthy: bridge={bridge_pid} supervisor={supervisor_pid} state={cloudflare!r}")
    cloudflared_pids = dc.exact_command_pids(CFG["cloudflared_command"], table)
    if cloudflared_pids != [cloudflared_pid]:
        problems.append(f"cloudflared process set {cloudflared_pids} != managed {cloudflared_pid} (no orphan exception configured)")
    installed_bridge = dc.sha256(dc.BRIDGE_SUPPORT / "tidey-remote-bridge")
    if installed_bridge != expected_hashes["bridge"]:
        problems.append("installed Bridge hash != expected")
    try:
        bridge_http, bridge_status = dc.bridge_admin_status()
    except Exception as error:  # noqa: BLE001
        bridge_http, bridge_status = None, {}
        problems.append(f"Bridge admin status error: {error}")
    tidey_pids = dc.exact_command_pids(str(dc.PRODUCTION / "Contents/MacOS/Tidey"), table)
    iterm_command = f"{dc.SUPPORT / CFG['iterm_support_name']} {dc.SUPPORT / 'iterm2-daemon-1.socket'}"
    iterm_pids = dc.exact_command_pids(iterm_command, table)
    if len(tidey_pids) != 1 or len(iterm_pids) != 1 or tidey_pids[0] != socket_pid:
        problems.append(f"service identity mismatch: Tidey={tidey_pids} socket-server={socket_pid} iTermServer={iterm_pids}")

    # --- holders ---
    production_holders = dc.lsof_holders(dc.PRODUCTION)
    archive_holders_by_root = {}
    for archive_dir in sorted(dc.ARCHIVE_ROOT.glob("*.bundle-archive")):
        if not archive_dir.is_dir() or archive_dir.is_symlink():
            problems.append(f"invalid retained archive entry: {archive_dir}")
            continue
        archive_holders_by_root[str(archive_dir)] = dc.lsof_holders(archive_dir)
    tccd_holders = [h for holders in archive_holders_by_root.values() for h in holders if dc.is_tccd_holder(h)]
    if tccd_holders:
        problems.append("tccd holds a deployment archive file: Tim must dismiss the TCC dialog (never probe or signal)")
    if args.kind == "predeploy":
        for root, holders in archive_holders_by_root.items():
            if holders:
                problems.append(f"retained archive has holders before deployment: {root} ({len(holders)})")
    else:
        base_wrappers = set(baseline[2]["production_wrapper_holder_pids"])
        for root, holders in archive_holders_by_root.items():
            wrappers = {h["pid"] for h in holders if dc.is_wrapper_holder(h)}
            others = [h for h in holders if not dc.is_wrapper_holder(h) and not dc.is_tccd_holder(h)]
            if root == str(dc.ARCHIVE):
                if others:
                    problems.append(f"non-wrapper holders inside the new archive: {[(h['pid'], h['command'], h['name']) for h in others][:6]}")
                if not wrappers <= base_wrappers:
                    problems.append(f"new-archive wrapper PIDs {sorted(wrappers - base_wrappers)} are not baseline wrappers")
            elif holders:
                problems.append(f"older archive has holders: {root} ({len(holders)})")

    hashes = {
        "candidate": {
            "tidey": dc.sha256(CANDIDATE / "Contents/MacOS/Tidey"),
            "itermserver": dc.sha256(CANDIDATE / "Contents/MacOS/iTermServer"),
            "bridge": dc.sha256(CANDIDATE / "Contents/Resources/RemoteBridge/tidey-remote-bridge"),
        },
        "production": {**production_hashes, "installed_bridge": installed_bridge,
                       "installed_itermserver": dc.sha256(dc.SUPPORT / CFG["iterm_support_name"])},
        "helpers": {"archive_helper": dc.sha256(CFG["archive_helper"]), "open_helper": dc.sha256(CFG["open_helper"])},
    }
    if hashes["candidate"] != CFG["candidate_hashes"]:
        problems.append(f"candidate hash drift: {hashes['candidate']!r}")
    if hashes["helpers"]["archive_helper"] != CFG["archive_helper_sha256"] or hashes["helpers"]["open_helper"] != CFG["open_helper_sha256"]:
        problems.append("canonical production helper hash drift")
    for command in (["/usr/bin/codesign", "--verify", "--deep", "--strict", str(CANDIDATE)],
                    ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(dc.PRODUCTION)]):
        if dc.run(command)[0]:
            problems.append(f"codesign verify failed: {command[-1]}")
    ls_text = dc.ls_dump()
    ls_problems, ls_facts = dc.ls_gate(ls_text, allow_current_archive=args.kind != "predeploy")
    problems.extend(ls_problems)  # production required in every phase; exact new root only during handoff

    if problems:
        print(json.dumps({"kind": args.kind, "problems": problems}, ensure_ascii=False, indent=2))
        dc.fail(f"{len(problems)} gate problem(s); checkpoint not written")

    # --- write the checkpoint (the only writes in this helper) ---
    CHECKPOINT.mkdir(mode=0o700)
    (CHECKPOINT / "databases").mkdir(mode=0o700)
    (CHECKPOINT / "tmux-captures").mkdir(mode=0o700)
    captured_at = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    dc.write_json(CHECKPOINT / "tidey-socket-snapshot.json", {"captured_at": captured_at, "kind": args.kind, **snapshot})
    db_results, db_metadata = {}, {}
    for name, source in {
        "restorable-state.sqlite": dc.SUPPORT / "SavedState/restorable-state.sqlite",
        "chatdb.sqlite": dc.SUPPORT / "chatdb.sqlite",
        "Tidey.sqlite": dc.SUPPORT / "Tidey.sqlite",
    }.items():
        if not source.is_file() or source.is_symlink():
            dc.fail(f"missing database: {source}")
        db_results[name] = dc.sqlite_backup(source, CHECKPOINT / "databases" / name)
        stat = source.stat()
        db_metadata[name] = {"path": str(source), "size": stat.st_size, "mtime_ns": stat.st_mtime_ns}
    if any(value != "ok" for value in db_results.values()):
        dc.fail(f"database quick_check failed: {db_results!r}")
    saved_copy_problems = dc.saved_state_matches(snapshot, dc.decode_saved_state(CHECKPOINT / "databases/restorable-state.sqlite"))
    if saved_copy_problems:
        dc.fail(f"checkpoint database copy does not match the captured live identities: {saved_copy_problems}")
    dc.write_json(CHECKPOINT / "database-quick-check.json", db_results)
    dc.write_json(CHECKPOINT / "database-metadata.json", db_metadata)
    shutil.copytree(dc.BRIDGE_SUPPORT / "agent-sessions", CHECKPOINT / "agent-sessions", symlinks=True)
    dc.write_json(CHECKPOINT / "registry-inventory.json", registries)
    dc.write_json(CHECKPOINT / "registry-topology.json", topology)
    for label, inv in tmux_inventory.items():
        (CHECKPOINT / f"tmux-sessions-{label}.txt").write_text(inv["sessions"], encoding="utf-8")
        dc.write_json(CHECKPOINT / f"tmux-pane-processes-{label}.json", inv["processes"])
        for pane_id, capture in inv["captures"].items():
            (CHECKPOINT / "tmux-captures" / f"{label}-{pane_id.lstrip('%')}.txt").write_text(capture, encoding="utf-8")
    dc.write_json(CHECKPOINT / "hashes.json", hashes)
    (CHECKPOINT / "processes.txt").write_text(dc.run_out(["/bin/ps", "-Ao", "pid=,ppid=,pgid=,lstart=,command="], check=True)[1], encoding="utf-8")
    (CHECKPOINT / "bridge-launchd.txt").write_text(bridge_launchd, encoding="utf-8")
    (CHECKPOINT / "cloudflare-launchd.txt").write_text(supervisor_launchd, encoding="utf-8")
    dc.write_json(CHECKPOINT / "bridge-admin-status.json", bridge_status)
    dc.write_json(CHECKPOINT / "cloudflared-state.json", cloudflare)
    dc.write_json(CHECKPOINT / "runtime-entries.json", [{"path": str(p), "inode": p.lstat().st_ino} for p in runtime_entries])
    dc.write_json(CHECKPOINT / "production-bundle-holders.json", production_holders)
    dc.write_json(CHECKPOINT / "deployment-backup-holders.json", archive_holders_by_root)
    (CHECKPOINT / "launchservices-dump.txt").write_text(ls_text, encoding="utf-8")
    dc.write_json(CHECKPOINT / "launchservices-facts.json", ls_facts)
    for filename, cmd in {
        "production-codesign-detail.txt": ["/usr/bin/codesign", "-dv", "--verbose=4", str(dc.PRODUCTION)],
        "candidate-codesign-detail.txt": ["/usr/bin/codesign", "-dv", "--verbose=4", str(CANDIDATE)],
        "tcp-4817.txt": ["/usr/sbin/lsof", "-nP", "-iTCP:4817", "-sTCP:LISTEN"],
    }.items():
        code, out, err = dc.run(cmd)
        (CHECKPOINT / filename).write_text(out + err, encoding="utf-8")
        if filename == "tcp-4817.txt" and code:
            dc.fail("no TCP 4817 listener")
    retained = [{"path": str(p), "inode": p.stat().st_ino} for p in sorted(dc.ARCHIVE_ROOT.glob("*.bundle-archive"))]
    dc.write_json(CHECKPOINT / "retained-archives.json", retained)
    (CHECKPOINT / "worktree-git-status.txt").write_text(git_status, encoding="utf-8")
    (CHECKPOINT / "worktree-staged.diff").write_text(staged_diff, encoding="utf-8")
    (CHECKPOINT / "worktree-working.diff").write_text(working_diff, encoding="utf-8")
    (CHECKPOINT / "worktree-identity.sha256").write_text(git_digest + "\n", encoding="utf-8")
    service_pids = {"tidey": tidey_pids[0], "tidey_socket_server": socket_pid, "itermserver": iterm_pids[0], "outgoing_tmux": outgoing_pid,
                    "candidate_tmux": candidate_pid, "bridge": bridge_pid, "cloudflare_supervisor": supervisor_pid, "cloudflared": cloudflared_pid}
    dc.write_json(CHECKPOINT / "service-pids.json", {"pids": service_pids, "commands": {k: dc.process_command(v) for k, v in service_pids.items() if v}})
    summary = {
        "checkpoint": str(CHECKPOINT), "kind": args.kind, "captured_at": captured_at, "baseline": args.baseline,
        "candidate_app": str(CANDIDATE), "candidate_head": head, "worktree_identity_sha256": git_digest,
        "planned_archive": str(dc.ARCHIVE), "archive_present": dc.ARCHIVE.exists(),
        "candidate_socket": str(dc.CANDIDATE_SOCKET), "candidate_socket_present": dc.CANDIDATE_SOCKET.exists(),
        "outgoing_socket": str(dc.OUTGOING_SOCKET), "outgoing_tmux_pid": outgoing_pid, "candidate_tmux_pid": candidate_pid,
        "workspace_count": len(workspace_ids), "panel_count": len(panel_ids), "workspace_ids": sorted(workspace_ids),
        "workspace_panel_identity_sha256": hashlib.sha256(json.dumps(sorted(panel_ids, key=repr)).encode()).hexdigest(),
        "descriptor_count": len(descriptors), "descriptor_sessions": sorted(by_session),
        "descriptor_socket_split": dict(descriptor_split),
        "registry_count": len(registries), "unique_durable_count": len(set(keys)),
        "registry_socket_split": dict(Counter(item["tmux_socket_path"] for item in gate["tmux"])),
        "native_writers": gate["native"], "itermserver_start": gate["daemon_start"],
        "production_wrapper_holder_pids": sorted({h["pid"] for h in production_holders if dc.is_wrapper_holder(h)}),
        "production_holder_commands": dict(Counter(h.get("command") for h in production_holders)),
        "archive_holder_counts": {root: len(h) for root, h in archive_holders_by_root.items()},
        "hashes": hashes, "service_pids": service_pids, "controllers": controllers,
        "bridge_http": bridge_http, "cloudflare_state": cloudflare.get("state"),
        "launchservices": ls_facts, "saved_state_session_nodes": dc.decode_saved_state()["session_count"],
        "database_quick_checks": db_results,
    }
    dc.write_json(CHECKPOINT / "summary.json", summary)
    print(json.dumps({k: summary[k] for k in ("checkpoint", "kind", "workspace_count", "panel_count", "descriptor_count", "registry_count",
                                                "unique_durable_count", "descriptor_socket_split", "registry_socket_split", "service_pids",
                                                "production_wrapper_holder_pids", "archive_holder_counts")}, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
