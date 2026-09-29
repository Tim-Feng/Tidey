#!/usr/bin/env python3
"""Read-only collectors extracted from the reviewed local deployment helpers.

Nothing in this module mutates production. Every mutation lives in the phase
helpers and is guarded by an explicit dry-run switch there.
"""
import hashlib
import importlib.util
from datetime import datetime
import json
import os
import plistlib
import socket
import sqlite3
import subprocess
import sys
import urllib.request
from collections import Counter
from pathlib import Path

# Configuration and effects are explicit per invocation. Importing this module
# never reads a prior job, production state, or any service.
CFG = {}
SUPPORT = BRIDGE_SUPPORT = PRODUCTION = SOCKET_API = None
OUTGOING_SOCKET = CANDIDATE_SOCKET = ARCHIVE_ROOT = ARCHIVE = None
TMUX = PIDINFO_EXECUTABLE = None
COMMAND_RUNNER = None
API_RUNNER = None
_CHECKS = None


class GateError(RuntimeError):
    pass


def configure(config, *, command_runner=None, api_runner=None):
    global CFG, SUPPORT, BRIDGE_SUPPORT, PRODUCTION, SOCKET_API
    global OUTGOING_SOCKET, CANDIDATE_SOCKET, ARCHIVE_ROOT, ARCHIVE
    global TMUX, PIDINFO_EXECUTABLE, COMMAND_RUNNER, API_RUNNER
    CFG = dict(config)
    SUPPORT = Path(CFG["support"])
    BRIDGE_SUPPORT = Path(CFG["bridge_support"])
    PRODUCTION = Path(CFG["production"])
    SOCKET_API = SUPPORT / "tidey.sock"
    OUTGOING_SOCKET = Path(CFG["outgoing_socket"])
    CANDIDATE_SOCKET = Path(CFG["candidate_socket"])
    ARCHIVE_ROOT = Path(CFG["archive_root"])
    ARCHIVE = ARCHIVE_ROOT / CFG["archive_name"]
    TMUX = CFG["tmux"]
    PIDINFO_EXECUTABLE = str(PRODUCTION / "Contents/XPCServices/pidinfo.xpc/Contents/MacOS/pidinfo")
    COMMAND_RUNNER = command_runner
    API_RUNNER = api_runner


def configure_file(path):
    source = Path(path)
    if not source.is_absolute() or source.is_symlink() or not source.is_file():
        raise GateError("configuration must be an explicit literal absolute file")
    config = json.loads(source.read_text(encoding="utf-8"))
    if config.get("schema") != "tidey.deploy.helpers/2":
        raise GateError("unexpected deployment configuration schema")
    configure(config)


def checks():
    """Use the shared skill's predicates, never a job-local copy."""
    global _CHECKS
    path = Path(CFG["checks_module"])
    if not path.is_absolute() or not path.is_file():
        raise GateError("shared checks require an explicit absolute module path")
    resolved = str(path.resolve())
    if _CHECKS is None or _CHECKS.__file__ != resolved:
        spec = importlib.util.spec_from_file_location("tidey_deployment_checks", resolved)
        _CHECKS = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_CHECKS)
    return _CHECKS


def evidence_path(path):
    path = Path(path)
    if not path.is_absolute() or os.path.normpath(str(path)) != str(path):
        raise GateError("evidence path must be literal and absolute")
    if not path.parent.is_dir() or any(p.is_symlink() for p in path.parents):
        raise GateError("evidence parent missing or symlinked")
    roots = [Path(CFG[k]) for k in ("task_dir", "checkpoint_root")]
    if not any(root != path and root in path.parents for root in roots):
        raise GateError("evidence path is outside this job/checkpoint scope")
    return path


def fail(message, code=1):
    print(f"STOP: {message}", file=sys.stderr)
    raise SystemExit(code)


def run(args, *, check=False, allow_codes=(0,)):
    """Run a command; stdout and stderr are captured separately."""
    runner = COMMAND_RUNNER or subprocess.run
    result = runner(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode not in allow_codes:
        raise GateError(f"command failed ({result.returncode}): {args!r}\n{result.stdout}\n{result.stderr}")
    return result.returncode, result.stdout, result.stderr


def run_out(args, *, check=False, allow_codes=(0,)):
    code, out, _ = run(args, check=check, allow_codes=allow_codes)
    return code, out


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, value):
    checks().write_evidence_once(evidence_path(path), value)


def literal_dir(path, label):
    path = Path(path)
    if path.is_symlink() or not path.is_dir():
        raise GateError(f"{label} is not a literal directory: {path}")
    return path


def request(action, params=None, *, request_id_prefix="push-deploy"):
    """Read-only unless the caller passes a mutating action name on purpose."""
    payload = {"id": f"{request_id_prefix}-{action}", "action": action, "params": params or {}}
    if API_RUNNER is not None:
        response = API_RUNNER(payload)
        if response.get("ok") is not True:
            raise GateError(f"API request failed: {action}")
        return response
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(12)
    client.connect(str(SOCKET_API))
    client.sendall(json.dumps(payload, separators=(",", ":")).encode() + b"\n")
    data = b""
    while b"\n" not in data:
        chunk = client.recv(1024 * 1024)
        if not chunk:
            raise GateError(f"socket closed before {action} response")
        data += chunk
    client.close()
    response = json.loads(data.split(b"\n", 1)[0])
    if not response.get("ok"):
        raise GateError(f"{action} failed: {response!r}")
    return response


# ---------------------------------------------------------------- processes

def process_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (ProcessLookupError, PermissionError, TypeError, ValueError):
        return False


def process_command(pid):
    code, output = run_out(["/bin/ps", "-ww", "-p", str(pid), "-o", "command="])
    if code or not output.strip():
        return None
    return output.strip()


def process_start(pid):
    code, output = run_out(["/bin/ps", "-p", str(pid), "-o", "lstart="])
    return output.strip() if not code else None


def classify_checkpoint_pids(starts, captured_at):
    try:
        return checks().classify_checkpoint_pids(starts, captured_at)
    except checks().GateError as error:
        raise GateError(str(error)) from error


def original_live_pids(pids, captured_at):
    requested = set(pids)
    if not requested:
        return [], []
    code, out, err = run(["/usr/bin/env", "LC_ALL=C", "/bin/ps", "-p",
                          ",".join(map(str, sorted(requested))), "-o", "pid=,lstart="])
    try:
        return checks().check_ps_result(requested, code, out, err, captured_at)
    except checks().GateError as error:
        raise GateError(str(error)) from error


def process_table():
    """pid -> (ppid, command) for every live process."""
    output = run_out(["/bin/ps", "-Ao", "pid=,ppid=,command="], check=True)[1]
    table = {}
    for line in output.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 2 or not parts[0].isdigit():
            continue
        table[int(parts[0])] = (int(parts[1]), parts[2] if len(parts) > 2 else "")
    return table


def descendants(root_pid, table=None):
    table = table if table is not None else process_table()
    children = {}
    for pid, (ppid, _) in table.items():
        children.setdefault(ppid, []).append(pid)
    result = []
    stack = list(children.get(int(root_pid), []))
    while stack:
        pid = stack.pop()
        result.append(pid)
        stack.extend(children.get(pid, []))
    return sorted(result)


def ancestors(pid, table=None):
    table = table if table is not None else process_table()
    chain = []
    seen = set()
    pid = int(pid)
    while pid in table and pid not in seen and pid > 1:
        seen.add(pid)
        chain.append(pid)
        pid = table[pid][0]
    return chain


def exact_command_pids(expected, table=None):
    table = table if table is not None else process_table()
    return sorted(pid for pid, (_, command) in table.items() if command.strip() == expected)


def executable_path(pid):
    """Executable text segment of a process from lsof (never inferred from argv)."""
    code, out, err = run(["/usr/sbin/lsof", "-nP", "-Fn", "-a", "-d", "txt", "-p", str(pid)])
    if code not in (0, 1) or err.strip():
        raise GateError(f"lsof txt inspection failed for {pid}: {err.strip()}")
    names = [line[1:] for line in out.splitlines() if line.startswith("n")]
    return names[0] if names else None


# ---------------------------------------------------------------- services

def launchd_pid(label):
    code, output = run_out(["/bin/launchctl", "print", f"gui/{os.getuid()}/{label}"])
    if code:
        return None, output
    matches = [int(line.strip().split("=", 1)[1]) for line in output.splitlines() if line.strip().startswith("pid = ")]
    if len(matches) != 1:
        return None, output
    return matches[0], output


def bridge_admin_status():
    token = json.loads((BRIDGE_SUPPORT / "pair-token.json").read_text(encoding="utf-8"))["token"]
    req = urllib.request.Request("http://127.0.0.1:4817/admin/status", headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=5) as response:
        return response.status, json.loads(response.read().decode("utf-8"))


def cloudflare_state():
    return json.loads((BRIDGE_SUPPORT / "cloudflared-state.json").read_text(encoding="utf-8"))


def fresh_service_problems(old, current, state, exact_cloudflared, boundary=None):
    return checks().fresh_service_problems(old, current, state, exact_cloudflared, boundary)


def check_fresh_services(baseline_pids, boundary=None):
    """Read-only live adapter. Caller records returned identities at the bridge boundary."""
    state = cloudflare_state()
    current = {"bridge_pid": launchd_pid(CFG["bridge_labels"]["bridge"])[0],
               "supervisor_pid": launchd_pid(CFG["bridge_labels"]["supervisor"])[0],
               "cloudflared_pid": state.get("process_id")}
    old = {"bridge_pid": baseline_pids["bridge"], "supervisor_pid": baseline_pids["cloudflare_supervisor"],
           "cloudflared_pid": baseline_pids["cloudflared"]}
    problems = fresh_service_problems(old, current, state, exact_command_pids(CFG["cloudflared_command"]), boundary)
    if problems:
        raise GateError("; ".join(problems))
    if any(process_alive(pid) for pid in old.values()):
        raise GateError("outgoing Bridge/supervisor/cloudflared PID still alive")
    if bridge_admin_status()[0] != 200:
        raise GateError("fresh Bridge HTTP status failed")
    return current


ITERM_ATTACH_MODES = {"installed-pre-new-server", "new-server-pre-stage", "phase1-pre"}
ITERM_FRESH_MODES = {"phase1-post", "phase2-pre", "phase2-post", "post-retirement"}


def itermserver_phase_problems(mode, observed, baseline, outgoing_hash, candidate_hash):
    return checks().itermserver_phase_problems(
        mode, observed, baseline, outgoing_hash, candidate_hash,
        str(SUPPORT / CFG["iterm_support_name"]))


def observe_itermserver(table=None):
    """Live read-only observation for itermserver_phase_problems."""
    table = table if table is not None else process_table()
    command = f"{SUPPORT / CFG['iterm_support_name']} {SUPPORT / 'iterm2-daemon-1.socket'}"
    pids = exact_command_pids(command, table)
    pid = pids[0] if len(pids) == 1 else None
    return {
        "support_hash": sha256(SUPPORT / CFG["iterm_support_name"]) if (SUPPORT / CFG["iterm_support_name"]).is_file() else None,
        "daemon_pid": pid,
        "daemon_command": process_command(pid) if pid else None,
        "daemon_executable": executable_path(pid) if pid else None,
        "daemon_pids": pids,
    }


def tidey_socket_server():
    """PID and executable of the process serving tidey.sock, proven through lsof, not argv."""
    code, out, err = run(["/usr/sbin/lsof", "-nP", "-F", "pn", "-U"])
    if code not in (0, 1) or (code == 1 and err.strip()):
        raise GateError(f"lsof unix-socket scan failed: {err.strip()}")
    pids = set()
    current = None
    for line in out.splitlines():
        if line.startswith("p"):
            current = int(line[1:])
        elif line.startswith("n") and line[1:] == str(SOCKET_API) and current is not None:
            pids.add(current)
    if len(pids) != 1:
        raise GateError(f"expected one process holding {SOCKET_API}, got {sorted(pids)}")
    pid = pids.pop()
    return pid, executable_path(pid)


# ---------------------------------------------------------------- databases

def quick_check(path):
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        return db.execute("PRAGMA quick_check").fetchone()[0]
    finally:
        db.close()


def sqlite_backup(source, destination):
    source_db = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
    destination_db = sqlite3.connect(str(destination))
    source_db.backup(destination_db)
    destination_db.close()
    source_db.close()
    return quick_check(destination)


def decode_saved_state(path=None):
    """Decode the NSKeyedArchiver workspace graph in the restoration database (read-only)."""
    path = path or (SUPPORT / "SavedState/restorable-state.sqlite")
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        row = db.execute("SELECT data FROM Node WHERE key='Tidey Workspace Restoration State'").fetchone()
        sessions = db.execute("SELECT data FROM Node WHERE key='Session'").fetchall()
    finally:
        db.close()
    if not row:
        raise GateError("restoration state node missing")
    archive = plistlib.loads(row[0])
    objects = archive["$objects"]

    def un(value):
        if isinstance(value, plistlib.UID):
            return un(objects[value.data])
        if isinstance(value, dict):
            if "NS.keys" in value:
                return {un(k): un(v) for k, v in zip(value["NS.keys"], value["NS.objects"])}
            if "NS.objects" in value:
                return [un(v) for v in value["NS.objects"]]
            return {k: un(v) for k, v in value.items() if k != "$class"}
        if isinstance(value, list):
            return [un(v) for v in value]
        return value

    root = un(archive["$top"]["root"])
    import re
    uuid = re.compile(rb"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")
    session_uuids = [sorted({m.decode() for m in uuid.findall(data or b"")}) for (data,) in sessions]
    return {"root": root, "session_count": len(sessions), "session_uuid_sets": session_uuids}


# ---------------------------------------------------------------- tmux

def tmux(socket_path, *args, check=True):
    return run_out([TMUX, "-S", str(socket_path), *args], check=check)


def tmux_server_pid(socket_path):
    code, output = tmux(socket_path, "display-message", "-p", "-t", "=tidey-runtime-canary", "#{pid}", check=False)
    value = output.strip()
    if code or not value.isdigit() or not process_alive(value):
        return None
    return int(value)


def tmux_pane_map(socket_path):
    """pane_id -> {session, window_index, window_name, pane_pid, command, cwd} for a live server."""
    code, output = tmux(socket_path, "list-panes", "-a", "-F",
                        "#{session_name}|#{session_id}|#{window_index}|#{window_name}|#{window_id}|#{pane_id}|#{pane_pid}|#{pane_current_command}|#{pane_current_path}", check=False)
    if code:
        raise GateError(f"list-panes failed on {socket_path}")
    panes = {}
    for line in output.splitlines():
        s, sid, widx, wname, wid, pane, ppid, cmd, cwd = line.split("|", 8)
        panes[pane] = {"session": s, "session_id": sid, "window_index": int(widx), "window_name": wname,
                       "window_id": wid, "pane_pid": int(ppid), "command": cmd, "cwd": cwd}
    return panes


def pane_of_pid(pid, panes, table):
    """The pane (on the given server) whose shell is an ancestor of pid, or None."""
    by_pane_pid = {info["pane_pid"]: pane for pane, info in panes.items()}
    for ancestor in ancestors(pid, table):
        if ancestor in by_pane_pid:
            return by_pane_pid[ancestor]
    return None


def caller_identity(table=None):
    """Where this helper itself runs: the tmux server socket and pane of its own ancestry.

    TMUX_PANE is not reliable (controller A runs without it), so the answer comes from the
    process tree: the nearest ancestor that is a tmux server (`tmux -S <socket> ...`)."""
    table = table if table is not None else process_table()
    chain = ancestors(os.getpid(), table)
    # Never parse argv (socket paths contain spaces). Resolve each literal Runtime socket to its
    # server PID through tmux itself and match that PID against the ancestor chain.
    server_pids = {}
    for sock in sorted((SUPPORT / "Runtime").glob("tmux-*.sock")):
        pid = tmux_server_pid(sock)
        if pid:
            server_pids[pid] = str(sock)
    return caller_identity_from(chain, server_pids)


def caller_identity_from(chain, server_pids):
    """Pure helper (fixture-testable): chain = ancestors nearest-first, server_pids = {pid: socket}."""
    for index, pid in enumerate(chain):
        if pid in server_pids:
            shell_pid = chain[index - 1] if index >= 1 else None
            return {"socket": server_pids[pid], "server_pid": pid, "pane_shell_pid": shell_pid}
    return {"socket": None, "server_pid": None, "pane_shell_pid": None}


# ---------------------------------------------------------------- registry

def registry_inventory(root=None):
    root = Path(root) if root else BRIDGE_SUPPORT / "agent-sessions"
    records = []
    for path in sorted(root.glob("*/*.json")):
        try:
            item = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(item, dict) or not item.get("session_id"):
            continue
        durable_id = durable_id_for(item)
        live_fields = {}
        for field in ("pid", "app_server_pid", "remote_tui_pid"):
            if item.get(field) is not None:
                live_fields[field] = process_alive(item.get(field))
        records.append({
            "path": str(path),
            "vendor": item.get("vendor"),
            "session_id": item.get("session_id"),
            "durable_id": durable_id,
            "workspace_id": item.get("workspace_id"),
            "panel_id": item.get("panel_id"),
            "tmux_socket_path": item.get("tmux_socket_path"),
            "tmux_pane_id": item.get("tmux_pane_id"),
            "pid": item.get("pid"),
            "app_server_pid": item.get("app_server_pid"),
            "remote_tui_pid": item.get("remote_tui_pid"),
            "rollout_path": item.get("rollout_path"),
            "runtime": item.get("runtime"),
            "thread_id": item.get("thread_id"),
            "resume_thread_id": item.get("resume_thread_id"),
            "live_fields": live_fields,
        })
    return records


def durable_id_for(item):
    """Product rule (ClaudeTranscriptSession.restoreSessionID): only a Codex app-server record
    uses thread_id ?? resume_thread_id ?? session_id; every other record uses session_id.
    `??` skips only missing values, so an empty current thread is invalid, never the old one."""
    if item.get("vendor") == "codex" and item.get("runtime") == "codex_app_server":
        chosen = next((item.get(k) for k in ("thread_id", "resume_thread_id", "session_id")
                       if item.get(k) is not None), None)
    else:
        chosen = item.get("session_id")
    return chosen if isinstance(chosen, str) and chosen.strip() else None


def durable_keys(records):
    return [(item["vendor"], item["durable_id"]) for item in records]


def unique_record(records, vendor, durable_id):
    matches = [r for r in records if r["vendor"] == vendor and r["durable_id"] == durable_id]
    if len(matches) != 1:
        raise GateError(f"expected exactly one registry record for {vendor}/{durable_id}, got {len(matches)}")
    return matches[0]


def registry_topology(records, table=None):
    """Prove each record's wrapper PID really sits in the pane it advertises on the socket it
    advertises. Returns (per_record, problems)."""
    table = table if table is not None else process_table()
    pane_maps = {}
    problems = []
    per_record = []
    for item in records:
        sock = item["tmux_socket_path"]
        if not sock or not item["tmux_pane_id"]:
            # Native writers are proven by classify_registries, never by a tmux socket path.
            problems.append(f"{item['vendor']}/{str(item['durable_id'])[:8]} has no tmux transport; not a tmux writer")
            continue
        if sock not in pane_maps:
            try:
                pane_maps[sock] = tmux_pane_map(sock) if Path(sock).is_socket() else {}
            except GateError:
                pane_maps[sock] = {}
        panes = pane_maps[sock]
        actual_pane = pane_of_pid(item["pid"], panes, table) if item["pid"] in table else None
        entry = {"durable_id": item["durable_id"], "vendor": item["vendor"], "socket": sock,
                 "registry_pane": item["tmux_pane_id"], "actual_pane": actual_pane,
                 "session": panes.get(actual_pane, {}).get("session") if actual_pane else None,
                 "window_name": panes.get(actual_pane, {}).get("window_name") if actual_pane else None}
        per_record.append(entry)
        if actual_pane != item["tmux_pane_id"]:
            problems.append(f"{item['vendor']}/{item['durable_id'][:8]} registry pane {item['tmux_pane_id']} but process ancestry says {actual_pane} on {sock}")
    return per_record, problems


# ---------------------------------------------------------------- snapshots

def socket_snapshot():
    workspaces = request("list_workspaces")
    panels = {}
    for workspace in workspaces["result"]["workspaces"]:
        workspace_id = workspace["workspace_id"]
        panels[workspace_id] = request("list_panels", {"workspace_id": workspace_id})
    descriptors = request("list_runtime_resume_descriptors")
    return {"workspaces": workspaces, "panels": panels, "runtime_resume_descriptors": descriptors}


def identity_sets(snapshot):
    workspace_ids = {item["workspace_id"] for item in snapshot["workspaces"]["result"]["workspaces"]}
    panel_ids = {
        stable_panel_key(workspace_id, panel)
        for workspace_id, response in snapshot["panels"].items()
        for panel in response["result"]["panels"]
    }
    descriptors = snapshot["runtime_resume_descriptors"]["result"]["descriptors"]
    # Native direct_resume carriers have no tmux target; split_descriptors
    # validates them instead of indexing every descriptor by tmux session.
    _, by_session = split_descriptors(descriptors)
    return workspace_ids, panel_ids, by_session


def split_descriptors(descriptors):
    """Keep native carriers separate from tmux session routing; never discard either."""
    native, tmux, carriers = {}, {}, set()
    for item in descriptors:
        binding, descriptor = item.get("binding", {}), item.get("descriptor", {})
        carrier = binding.get("panel_id")
        if not carrier or not binding.get("workspace_id") or carrier in carriers:
            raise GateError("missing or duplicate stable carrier")
        carriers.add(carrier)
        policy = descriptor.get("restore_policy")
        if policy == "direct_resume":
            agent = descriptor.get("agent", {})
            launch = agent.get("launch", {})
            if (descriptor.get("kind") != "agent" or "target" in descriptor
                    or not agent.get("durable_resume_id") or not agent.get("vendor")
                    or not launch.get("executable") or not launch.get("arguments")
                    or not launch.get("cwd")):
                raise GateError("invalid native direct_resume descriptor")
            native[carrier] = item
        elif policy == "create" and descriptor.get("kind") == "agent":
            target = descriptor.get("target", {})
            session = target.get("tmux_session")
            if not session or not target.get("socket_path") or not descriptor.get("topology"):
                raise GateError("tmux create descriptor needs target and topology")
            if session in tmux:
                raise GateError("duplicate descriptor tmux_session in snapshot")
            tmux[session] = item
        else:
            raise GateError("non-durable or unknown descriptor policy")
    return native, tmux


NATIVE_KIND = "native_session"
# Runtime-evidence flags and the revision counter legitimately change across a restart; the
# revision is still checked for regression. Every other field, known or not, stays compared.
NATIVE_DESCRIPTOR_TRANSIENT = ("revision", "awaiting_runtime_evidence", "staged")


def native_descriptor_problems(baseline, current):
    """Cross-phase comparison of native carriers on their stable projection."""
    def native(snapshot):
        return split_descriptors(snapshot["runtime_resume_descriptors"]["result"]["descriptors"])[0]
    try:
        base, cur = native(baseline), native(current)
    except GateError as error:
        return [str(error)]
    problems = []
    if set(base) != set(cur):
        problems.append(f"native carrier set drift: {sorted(set(base) ^ set(cur))}")
    for carrier in sorted(set(base) & set(cur)):
        project = lambda item: {k: v for k, v in item.items() if k not in NATIVE_DESCRIPTOR_TRANSIENT}
        if project(base[carrier]) != project(cur[carrier]):
            problems.append(f"native descriptor identity drift on carrier {carrier[:8]}")
        if not isinstance(cur[carrier].get("revision"), int) or cur[carrier]["revision"] < base[carrier].get("revision", 0):
            problems.append(f"native descriptor revision regressed on carrier {carrier[:8]}")
    return problems


def native_logical_parts(panel_id):
    parts = panel_id.split(":") if isinstance(panel_id, str) else []
    if len(parts) != 3 or parts[0] != "native-session" or not parts[1] or not parts[2]:
        return None
    return parts[1], parts[2]


def stable_panel_key(workspace_id, panel):
    """Cross-phase panel identity. A native logical id embeds the native session instance,
    which a fresh iTermServer replaces, so native panels key on their verified carrier."""
    kind = panel.get("logical_kind")
    if kind == NATIVE_KIND:
        parts = native_logical_parts(panel.get("panel_id"))
        if not parts or parts != (panel.get("carrier_panel_id"), panel.get("native_session_id")):
            raise GateError(f"native panel {panel.get('panel_id')!r} is not self-consistent with its carrier/session")
        return (workspace_id, kind, parts[0], panel.get("panel_index"))
    if not panel.get("panel_id"):
        raise GateError("panel without panel_id")
    return (workspace_id, kind, panel["panel_id"], panel.get("panel_index"))


def native_panels(snapshot):
    """Authoritative native panels from list_panels; missing or non-positive shell PID is typed."""
    panels, problems = [], []
    for workspace_id, response in snapshot["panels"].items():
        for panel in response["result"]["panels"]:
            if panel.get("logical_kind") != NATIVE_KIND:
                continue
            stable_panel_key(workspace_id, panel)
            pid = panel.get("effective_shell_pid")
            if type(pid) is not int or pid <= 1:
                problems.append(f"native_shell_pid_invalid: panel {panel['panel_id']}")
                continue
            panels.append({"workspace_id": workspace_id, "panel_id": panel["panel_id"],
                           "carrier": panel["carrier_panel_id"], "native_session_id": panel["native_session_id"],
                           "shell_pid": pid})
    return panels, problems


def classify_registries(records, snapshot, table, daemon_pid):
    """Split registry writers into tmux records and proven native writers.

    None/None tmux fields only mean "no tmux transport"; a record is native only when its
    process ancestry reaches exactly one authoritative native panel shell that runs under the
    current iTermServer daemon. Anything else is a typed problem, never a guessed socket."""
    panels, problems = native_panels(snapshot)
    native_desc, tmux_desc = split_descriptors(snapshot["runtime_resume_descriptors"]["result"]["descriptors"])
    tmux_launch_args = {arg for item in tmux_desc.values()
                        for w in item["descriptor"]["topology"].get("windows", [])
                        for pane in w.get("panes", []) for arg in pane.get("launch", {}).get("arguments", [])}
    tmux_records, native = [], {}
    for item in records:
        label = f"{item.get('vendor')}/{item.get('path')}"
        if not item.get("durable_id"):
            problems.append(f"invalid_durable: {label}")
            continue
        key = (item["vendor"], item["durable_id"])
        sock, pane = item.get("tmux_socket_path"), item.get("tmux_pane_id")
        if sock and pane:
            if item["durable_id"] not in tmux_launch_args:
                problems.append(f"tmux_descriptor_mismatch: {key} is not launched by any tmux descriptor")
            tmux_records.append(item)
            continue
        if sock or pane:
            problems.append(f"partial_transport: {label}")
            continue
        pid = item.get("pid")
        if type(pid) is not int or pid not in table:
            problems.append(f"unresolved_transport: {label} has no tmux fields and no live PID")
            continue
        chain = ancestors(pid, table)
        hits = [p for p in panels if p["shell_pid"] in chain]
        if len(hits) != 1:
            problems.append(f"unresolved_transport: {label} ancestry reaches {len(hits)} native panel shells")
            continue
        panel = hits[0]
        if item.get("workspace_id") != panel["workspace_id"] or item.get("panel_id") not in {panel["panel_id"], panel["carrier"]}:
            problems.append(f"native_identity_mismatch: {label} registry workspace/panel differs from its ancestry panel")
            continue
        if daemon_pid not in chain or chain.index(daemon_pid) < chain.index(panel["shell_pid"]):
            problems.append(f"native_not_under_daemon: {label}")
            continue
        desc = native_desc.get(panel["carrier"])
        agent = desc["descriptor"]["agent"] if desc else {}
        if not desc or desc["binding"]["workspace_id"] != panel["workspace_id"]:
            problems.append(f"missing_native_descriptor: {key} on carrier {panel['carrier'][:8]}")
            continue
        if (agent.get("vendor"), agent.get("durable_resume_id")) != key:
            problems.append(f"native_descriptor_mismatch: {key} vs descriptor {(agent.get('vendor'), agent.get('durable_resume_id'))}")
            continue
        if key in native:
            problems.append(f"duplicate_native_writer: {key}")
            continue
        native[key] = {"workspace_id": panel["workspace_id"], "carrier": panel["carrier"],
                       "native_session_id": panel["native_session_id"], "pid": pid, "shell_pid": panel["shell_pid"]}
    carriers = Counter(w["carrier"] for w in native.values())
    problems.extend(f"duplicate_native_carrier: {c}" for c, n in carriers.items() if n > 1)
    # Coverage is anchored in the authoritative native agent descriptors, not only in the
    # records that happened to be found: each needs its panel and exactly one proven writer.
    # A native panel with no agent descriptor (a plain shell) is not required to have one.
    for carrier, desc in sorted(native_desc.items()):
        workspace = desc["binding"]["workspace_id"]
        if not any(p["carrier"] == carrier and p["workspace_id"] == workspace for p in panels):
            problems.append(f"native_descriptor_without_panel: carrier {carrier[:8]} in {workspace}")
        elif carriers.get(carrier, 0) == 0:
            problems.append(f"native_descriptor_without_writer: carrier {carrier[:8]} has no proven registry writer")
    return tmux_records, native, problems


def parse_process_start(value):
    try:
        return datetime.strptime(value, "%a %b %d %H:%M:%S %Y")
    except (TypeError, ValueError):
        return None


def native_generation_problems(generation, writers, baseline_writers, daemon_start=None):
    """Tie each native writer to the verified iTermServer generation.

    writers: {key: {..., "start": lstart}} for the current phase.
    baseline_writers: the checkpoint's native writers (with carrier, pid and start).
    generation: "baseline" (record), "attach" (same PID and birth) or "fresh" (born at or
    after the current daemon; ancestry is already proven by classify_registries).
    An unreadable birth is never read as absent or as a new generation."""
    problems = []
    for key, cur in sorted(writers.items()):
        if parse_process_start(cur.get("start")) is None:
            problems.append(f"native_birth_unreadable: {key}")
    if generation == "baseline":
        return problems
    if baseline_writers is None:
        return problems + ["checkpoint_missing_native_generation: baseline has no native writer evidence"]
    if set(writers) != set(baseline_writers):
        missing, extra = set(baseline_writers) - set(writers), set(writers) - set(baseline_writers)
        problems.append(f"native_not_restored: missing {sorted(missing)} extra {sorted(extra)}")
    for key in sorted(set(writers) & set(baseline_writers)):
        cur, base = writers[key], baseline_writers[key]
        if (cur["workspace_id"], cur["carrier"]) != (base.get("workspace_id"), base.get("carrier")):
            problems.append(f"native_carrier_changed: {key}")
        if generation == "attach":
            if not base.get("pid") or parse_process_start(base.get("start")) is None:
                problems.append(f"checkpoint_missing_native_birth: {key}")
            elif (cur["pid"], cur.get("start")) != (base["pid"], base["start"]):
                problems.append(f"native_generation_changed_during_attach: {key}")
        elif generation == "fresh":
            born, daemon = parse_process_start(cur.get("start")), parse_process_start(daemon_start)
            if daemon is None:
                problems.append("daemon_birth_unreadable")
            elif born is not None and born < daemon:
                problems.append(f"native_older_than_daemon: {key}")
        else:
            problems.append(f"unknown native generation {generation!r}")
    return problems


def native_generation_for(mode):
    if mode == "preinstall" or mode in checks().ATTACH_MODES:
        return "attach"
    if mode in checks().FRESH_MODES:
        return "fresh"
    raise GateError(f"unknown mode {mode}")


def saved_state_matches(snapshot, saved=None):
    """Compare the decoded restoration graph with a live/captured socket snapshot."""
    saved = saved or decode_saved_state()
    root = saved["root"]
    problems = []
    live_ws = {w["workspace_id"]: w for w in snapshot["workspaces"]["result"]["workspaces"]}
    saved_ws = {w.get("id") or w.get("workspace_id"): w for w in root.get("workspaces", [])}
    if set(live_ws) != set(saved_ws):
        problems.append(f"saved workspace ids differ from live: {sorted(set(live_ws) ^ set(saved_ws))}")
    for wid, w in saved_ws.items():
        if wid not in live_ws:
            continue
        live_panels = [p["carrier_panel_id"] for p in snapshot["panels"][wid]["result"]["panels"]]
        if sorted(w.get("panel_ids", [])) != sorted(live_panels):
            problems.append(f"saved panel ids for {wid} differ from live")
    rd = root.get("runtime_descriptors_by_panel_id", {})
    live_desc = {item["binding"]["panel_id"]: item for item in snapshot["runtime_resume_descriptors"]["result"]["descriptors"]}
    if set(rd) != set(live_desc):
        problems.append(f"saved descriptor panel set differs from live: {sorted(set(rd) ^ set(live_desc))}")
    for panel_id, saved_desc in rd.items():
        live = live_desc.get(panel_id)
        if not live:
            continue
        saved_copy = {k: v for k, v in saved_desc.items() if k != "revision"}
        if saved_copy != live["descriptor"]:
            problems.append(f"saved descriptor for panel {panel_id[:8]} differs from live")
        if saved_desc.get("revision") != live.get("revision"):
            problems.append(f"saved descriptor revision for panel {panel_id[:8]} {saved_desc.get('revision')} != live {live.get('revision')}")
    return problems


# ---------------------------------------------------------------- holders

def lsof_holders(root):
    """Actual open-file holders under a literal root (lsof -F parsing; never inferred from argv).

    Fails closed: the root must be a literal directory; lsof must exit 0 (matches) or exit 1
    with empty stderr (legitimate no matches); any stderr or parse gap is an error."""
    root = literal_dir(root, "holder root")
    code, out, err = run(["/usr/sbin/lsof", "-nP", "-Fpcfan", "+D", str(root)])
    # lsof exits 1 whenever any listed item had nothing to report (including "no open
    # files under root"); with empty stderr that is a legitimate result. Any stderr text or
    # another exit code is an inspection failure and must not be read as "no holders".
    if code not in (0, 1) or err.strip():
        raise GateError(f"lsof holder scan failed on {root}: exit {code}: {err.strip()[:400]}")
    if not out.strip():
        return []
    return parse_lsof_fields(out, root)


def parse_lsof_fields(out, root="<fixture>"):
    """Parse `lsof -Fpcfan` output; every file set (f) must carry a name (n); unknown tags
    are an error so a field that could hide a name never passes silently."""
    records = []
    current = {}
    f_count = n_count = 0
    for raw in out.splitlines():
        if not raw:
            continue
        tag, value = raw[0], raw[1:]
        if tag == "p":
            if not value.isdigit():
                raise GateError(f"unparseable lsof pid field: {raw!r}")
            current = {"pid": int(value)}
        elif tag == "c":
            current["command"] = value
        elif tag == "f":
            f_count += 1
            current = {"pid": current.get("pid"), "command": current.get("command"), "fd": value}
        elif tag == "a":
            current["access"] = value
        elif tag == "n":
            n_count += 1
            record = dict(current)
            record["name"] = value
            if record.get("pid") is None or record.get("command") is None or record.get("fd") is None:
                raise GateError(f"incomplete lsof record: {record!r}")
            records.append(record)
        else:
            raise GateError(f"unknown lsof field tag {tag!r} in {raw!r}")
    if f_count != n_count:
        raise GateError(f"lsof output has {f_count} file sets but {n_count} names for {root}")
    if not records:
        raise GateError(f"lsof exit 0 but no parseable holder records for {root}")
    return records


def argv_holders(root, table=None):
    """Processes whose argv mentions the root (complements lsof for the final gate)."""
    table = table if table is not None else process_table()
    root = str(root)
    return [{"pid": pid, "command": command} for pid, (_, command) in table.items()
            if root in command and pid != os.getpid()]


def is_wrapper_holder(record):
    return (
        record.get("command") == "bash"
        and str(record.get("fd", "")).startswith("255")
        and (record.get("name", "").endswith("/Contents/Resources/bin/claude")
             or record.get("name", "").endswith("/Contents/Resources/bin/codex"))
    )


def is_tccd_holder(record):
    return record.get("command") == "tccd" and process_command(record.get("pid")) == \
        "/System/Library/PrivateFrameworks/TCC.framework/Support/tccd"


# ---------------------------------------------------------------- LaunchServices

def ls_dump():
    """Complete lsregister dump text; requires exit 0 (no SIGPIPE-prone pipelines)."""
    code, out, err = run([CFG["lsregister"], "-dump"])
    if code != 0 or not out:
        raise GateError(f"lsregister -dump failed: exit {code}: {err.strip()[:300]}")
    return out


def ls_records(dump_text):
    """Parse dump records (separated by dashed lines) into dicts of lowercase keys."""
    records = []
    current = {}
    for line in dump_text.splitlines():
        if line.startswith("-----"):
            if current:
                records.append(current)
            current = {}
            continue
        if ":" in line and not line.startswith(" "):
            key, _, value = line.partition(":")
            current[key.strip().lower()] = value.strip()
    if current:
        records.append(current)
    return records


def _ls_strip(value):
    return value.rsplit(" (0x", 1)[0].strip() if value else ""


def ls_path(record):
    return _ls_strip(record.get("path", ""))


def ls_identifier(record):
    return _ls_strip(record.get("identifier", ""))


def ls_gate(dump_text=None, *, allow_current_archive=False):
    """Return (problems, facts) for the LaunchServices acceptance rules."""
    dump_text = dump_text or ls_dump()
    records = ls_records(dump_text)
    tidey = [r for r in records if ls_identifier(r) == "com.tidey.app"]
    tidey_paths = sorted({ls_path(r) for r in tidey})
    archive_root_records = [ls_path(r) for r in records if ls_path(r).startswith(str(ARCHIVE_ROOT) + "/")
                            and ls_path(r).endswith(".bundle-archive")]
    nested_archive_records = [ls_path(r) for r in records if ls_path(r).startswith(str(ARCHIVE_ROOT) + "/")
                              and not ls_path(r).endswith(".bundle-archive")]
    problems = []
    # Contract: production must be registered as com.tidey.app and no com.tidey.app record may
    # point into Deployment Backups. Other com.tidey.app records (DerivedData build products,
    # Desktop/Trash copies) are pre-existing facts, reported but not gated here.
    if str(PRODUCTION) not in tidey_paths:
        problems.append(f"production {PRODUCTION} is not registered as com.tidey.app (records: {tidey_paths[:6]})")
    into_backups = [p for p in tidey_paths if p.startswith(str(ARCHIVE_ROOT) + "/")]
    # During the ordered handoff only this exact newly archived root may re-register while
    # old wrappers are deliberately retained. Never allow another archive or nested Tidey.
    allowed = {str(ARCHIVE)} if allow_current_archive else set()
    into_backups = [p for p in into_backups if p not in allowed]
    if into_backups:
        problems.append(f"com.tidey.app records point into Deployment Backups: {into_backups}")
    forbidden_roots = [p for p in archive_root_records if p not in allowed]
    if forbidden_roots:
        problems.append(f"archive roots still registered: {forbidden_roots}")
    facts = {"com_tidey_app_paths": tidey_paths, "com_tidey_app_other_paths": [p for p in tidey_paths if p != str(PRODUCTION)],
             "archive_root_records": archive_root_records,
             "transitional_archive_records": sorted(set(archive_root_records) & allowed),
             "nested_archive_records": sorted(set(nested_archive_records)),
             "record_count": len(records)}
    return problems, facts


# ---------------------------------------------------------------- checkpoints

def load_checkpoint(path):
    path = literal_dir(path, "checkpoint")
    baseline = json.loads((path / "tidey-socket-snapshot.json").read_text(encoding="utf-8"))
    registries = json.loads((path / "registry-inventory.json").read_text(encoding="utf-8"))
    summary = json.loads((path / "summary.json").read_text(encoding="utf-8"))
    return baseline, registries, summary
