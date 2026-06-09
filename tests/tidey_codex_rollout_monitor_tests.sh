#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_UNDER_TEST="$SCRIPT_DIR/../Resources/bin/codex"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_monitor_capture_test() {
    local workspace_id="$1"
    local expected_file_state="$2"
    local tmpdir
    local marker
    local iteration

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/tidey-codex-monitor-tests.XXXXXX")"
    marker="$tmpdir/monitor.txt"

    MARKER="$marker" WORKSPACE_ID="$workspace_id" CODEX_UNDER_TEST="$CODEX_UNDER_TEST" bash -c '
        set -euo pipefail
        source "$CODEX_UNDER_TEST"
        monitor_rollout_and_registry() {
            printf "%s|%s|%s|%s|%s\n" "$1" "$2" "$3" "$4" "$5" > "$MARKER"
        }
        start_rollout_monitor_if_needed "12345" "${WORKSPACE_ID}" "panel-1" "/tmp/tidey" "2026-04-19T12:34:56Z"
    '

    if [[ "$expected_file_state" == "present" ]]; then
        for iteration in $(seq 1 50); do
            [[ -f "$marker" ]] && break
            sleep 0.02
        done
        [[ -f "$marker" ]] || fail "monitor did not start for workspace '$workspace_id'"
        [[ "$(cat "$marker")" == "12345|$workspace_id|panel-1|/tmp/tidey|2026-04-19T12:34:56Z" ]] || fail "unexpected monitor arguments"
    else
        sleep 0.1
        [[ ! -f "$marker" ]] || fail "monitor started unexpectedly for workspace '$workspace_id'"
    fi

    rm -rf "$tmpdir"
}

run_monitor_capture_test "workspace-1" "present"
run_monitor_capture_test "" "absent"

run_placeholder_cleanup_test() {
    local tmpdir
    local initial_registry
    local expected_registry
    local rm_log

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/tidey-codex-monitor-tests.XXXXXX")"
    initial_registry="$tmpdir/codex-initial-session.json"
    expected_registry="$tmpdir/codex-019d70fe-fd27-7a12-a3f7-9c89ae5048b6.json"
    rm_log="$tmpdir/rm.log"

    TMPDIR_CASE="$tmpdir" INITIAL_REGISTRY="$initial_registry" EXPECTED_REGISTRY="$expected_registry" RM_LOG="$rm_log" CODEX_UNDER_TEST="$CODEX_UNDER_TEST" bash -c '
        set -euo pipefail
        source "$CODEX_UNDER_TEST"

        REGISTRY_ROOT="$TMPDIR_CASE"
        write_registry_file "$INITIAL_REGISTRY" "workspace-1" "initial-session" "panel-1" "12345" "/tmp/tidey" "2026-04-21T13:40:00Z" ""

        __kill_calls=0
        kill() {
            __kill_calls=$((__kill_calls + 1))
            if [[ $__kill_calls -le 2 ]]; then
                return 0
            fi
            return 1
        }

        sleep() { :; }

        rollout_for_pid_tree() {
            printf "/Users/timfeng/.codex/sessions/2026/04/09/rollout-2026-04-09T14-47-32-019d70fe-fd27-7a12-a3f7-9c89ae5048b6.jsonl"
        }

        rm() {
            printf "%s\n" "$*" >> "$RM_LOG"
            if [[ "$1" == "-f" && "$2" == "$EXPECTED_REGISTRY" ]]; then
                return 0
            fi
            command rm "$@"
        }

        monitor_rollout_and_registry "12345" "workspace-1" "panel-1" "/tmp/tidey" "2026-04-21T13:40:00Z" "$INITIAL_REGISTRY" "initial-session"

        [[ ! -f "$INITIAL_REGISTRY" ]] || fail "placeholder registry was not removed"
        [[ -f "$EXPECTED_REGISTRY" ]] || fail "real rollout registry was not created"
        grep -q "$INITIAL_REGISTRY" "$RM_LOG" || fail "placeholder registry removal was not recorded"
        grep -q "$EXPECTED_REGISTRY" "$RM_LOG" || fail "real registry cleanup was not attempted"
    '

    rm -rf "$tmpdir"
}

run_placeholder_cleanup_test

run_stable_profile_paths_test() {
    local tmpdir

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/tidey-codex-profile-tests.XXXXXX")"

    HOOK_TEST_DIR="$tmpdir" CODEX_UNDER_TEST="$CODEX_UNDER_TEST" bash -c '
        set -euo pipefail
        source "$CODEX_UNDER_TEST"

        real_home="$HOOK_TEST_DIR/real-home"
        mkdir -p "$real_home"

        profile_name="$(stable_codex_profile_name "tidey-codex")"
        [[ "$profile_name" == "tidey-codex-tidey-codex" ]] || fail "profile name is not stable per session"

        sqlite_home="$(stable_codex_sqlite_home "$real_home" "tidey-codex")"
        [[ "$sqlite_home" == "$real_home/.tmp/tidey-codex-sqlite-tidey-codex" ]] || fail "sqlite home is not stable per session"

        sqlite_home="$(stable_codex_sqlite_home "$real_home")"
        [[ "$sqlite_home" == "$real_home/.tmp/tidey-codex-sqlite-default" ]] || fail "fallback sqlite home changed"
    '

    rm -rf "$tmpdir"
}

run_stable_profile_paths_test

run_profile_config_test() {
    local tmpdir

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/tidey-codex-profile-tests.XXXXXX")"

    HOOK_TEST_DIR="$tmpdir" CODEX_UNDER_TEST="$CODEX_UNDER_TEST" bash -c '
        set -euo pipefail
        source "$CODEX_UNDER_TEST"

        real_home="$HOOK_TEST_DIR/real-home"
        profile_name="$(stable_codex_profile_name "tidey-codex")"
        sqlite_home="$(stable_codex_sqlite_home "$real_home" "tidey-codex")"
        dispatch_script="/tmp/Tidey Dev.app/Contents/Resources/bin/codex-hook-dispatch"
        stale_dispatch_script="/Users/timfeng/GitHub/Tidey/Resources/bin/codex-hook-dispatch"
        mkdir -p "$real_home"
        printf "%s\n" "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"/tmp/user-hook\"},{\"type\":\"command\",\"command\":\"'\''$stale_dispatch_script'\'' stop\",\"timeout\":10}]}],\"UserPromptSubmit\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"'\''$stale_dispatch_script'\'' user-prompt-submit\",\"timeout\":10}]}]}}" > "$real_home/hooks.json"

        merge_tidey_hooks_into_user_hooks "$real_home" "$dispatch_script"
        write_tidey_profile_config "$real_home" "$profile_name" "$sqlite_home" "$dispatch_script"
        merge_tidey_hooks_into_user_hooks "$real_home" "$dispatch_script"
        write_tidey_profile_config "$real_home" "$profile_name" "$sqlite_home" "$dispatch_script"

        [[ -d "$sqlite_home" ]] || fail "sqlite home was not created"
        [[ -f "$real_home/$profile_name.config.toml" ]] || fail "profile config was not created"

        python3 - "$real_home/$profile_name.config.toml" "$real_home/hooks.json" "$sqlite_home" "$dispatch_script" <<'"'"'PY'"'"'
from pathlib import Path
import json
import sys

profile_path = sys.argv[1]
hooks_path = Path(sys.argv[2])
sqlite_home = sys.argv[3]
dispatch_script = sys.argv[4]
text = Path(profile_path).read_text()
hooks_root = json.loads(hooks_path.read_text())

if f"sqlite_home = \"{sqlite_home}\"" not in text:
    raise SystemExit("sqlite_home was not written")
if "hooks = true" not in text:
    raise SystemExit("hooks feature was not enabled")
if "\n[hooks]\n" in text or "[[hooks." in text:
    raise SystemExit("profile config should not declare hooks")
if "notify" in text:
    raise SystemExit("profile config should not copy notify from user config")
if "[projects." in text:
    raise SystemExit("profile config should not copy project trust sections")

quote = chr(39)
expected_commands = [
    f"{quote}{dispatch_script}{quote} session-start",
    f"{quote}{dispatch_script}{quote} user-prompt-submit",
    f"{quote}{dispatch_script}{quote} stop",
]
for command in expected_commands:
    if command not in json.dumps(hooks_root):
        raise SystemExit(f"missing Tidey hook command in hooks.json: {command}")

hooks_json = json.dumps(hooks_root)
if "/tmp/user-hook" not in hooks_json:
    raise SystemExit("existing user hook was not preserved")
if "/Users/timfeng/GitHub/Tidey/Resources/bin/codex-hook-dispatch" in hooks_json:
    raise SystemExit("stale Tidey hook command was not pruned")

for state_fragment in [":session_start:", ":user_prompt_submit:", ":stop:"]:
    if state_fragment not in text:
        raise SystemExit(f"missing Tidey hook trust state: {state_fragment}")
PY
    '

    rm -rf "$tmpdir"
}

run_profile_config_test

run_resolve_real_codex_home_detects_session_overlay_test() {
    local tmpdir

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/tidey-codex-profile-tests.XXXXXX")"

    HOOK_TEST_DIR="$tmpdir" CODEX_UNDER_TEST="$CODEX_UNDER_TEST" bash -c '
        set -euo pipefail
        source "$CODEX_UNDER_TEST"

        HOME="$HOOK_TEST_DIR/home"
        mkdir -p "$HOME/.codex/.tmp/tidey-codex-home-tidey-codex"
        CODEX_HOME="$HOME/.codex/.tmp/tidey-codex-home-tidey-codex"
        resolved="$(resolve_real_codex_home)"
        [[ "$resolved" == "$HOME/.codex" ]] || fail "session overlay was not resolved back to real CODEX_HOME"
    '

    rm -rf "$tmpdir"
}

run_resolve_real_codex_home_detects_session_overlay_test

run_codex_profile_flag_detection_test() {
    local tmpdir
    local fake_codex

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/tidey-codex-profile-flag-tests.XXXXXX")"
    fake_codex="$tmpdir/codex"

    CODEX_UNDER_TEST="$CODEX_UNDER_TEST" FAKE_CODEX="$fake_codex" bash -c '
        set -euo pipefail
        source "$CODEX_UNDER_TEST"

        printf "%s\n" "#!/usr/bin/env bash" "printf \"%s\\n\" \"Usage: codex --profile-v2 <CONFIG_PROFILE_V2>\"" > "$FAKE_CODEX"
        chmod +x "$FAKE_CODEX"
        [[ "$(codex_profile_flag "$FAKE_CODEX")" == "--profile-v2" ]] || fail "legacy profile flag was not detected"

        printf "%s\n" "#!/usr/bin/env bash" "printf \"%s\\n\" \"Usage: codex --profile <CONFIG_PROFILE_V2>\"" > "$FAKE_CODEX"
        chmod +x "$FAKE_CODEX"
        [[ "$(codex_profile_flag "$FAKE_CODEX")" == "--profile" ]] || fail "current profile flag was not detected"

        printf "%s\n" "#!/usr/bin/env bash" "printf \"%s\\n\" \"Usage: codex\"" > "$FAKE_CODEX"
        chmod +x "$FAKE_CODEX"
        [[ "$(codex_profile_flag "$FAKE_CODEX")" == "--profile" ]] || fail "fallback profile flag changed"
    '

    rm -rf "$tmpdir"
}

run_codex_profile_flag_detection_test

run_app_server_registry_metadata_test() {
    local tmpdir
    local registry

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/tidey-codex-app-server-registry-tests.XXXXXX")"
    registry="$tmpdir/codex-session.json"

    TMPDIR_CASE="$tmpdir" REGISTRY="$registry" CODEX_UNDER_TEST="$CODEX_UNDER_TEST" bash -c '
        set -euo pipefail
        source "$CODEX_UNDER_TEST"

        REGISTRY_ROOT="$TMPDIR_CASE"
        write_registry_file "$REGISTRY" "workspace-1" "session-1" "panel-1" "12345" "/tmp/tidey" "2026-06-07T00:00:00Z" "" "codex_app_server" "/tmp/tidey-codex/app.sock" "23456" "34567"
    '

    python3 - "$registry" <<'PY'
from pathlib import Path
import json
import sys

root = json.loads(Path(sys.argv[1]).read_text())
assert root["runtime"] == "codex_app_server"
assert root["app_server_socket"] == "/tmp/tidey-codex/app.sock"
assert root["app_server_pid"] == 23456
assert root["remote_tui_pid"] == 34567
PY

    rm -rf "$tmpdir"
}

run_app_server_registry_metadata_test

run_stale_app_server_registry_cleanup_test() {
    local tmpdir
    local live_registry
    local live_owner_dead_registry
    local stale_registry
    local stale_starting_registry
    local socket
    local socket_pid

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/tidey-codex-stale-registry-tests.XXXXXX")"
    live_registry="$tmpdir/codex-live.json"
    live_owner_dead_registry="$tmpdir/codex-live-owner-dead.json"
    stale_registry="$tmpdir/codex-stale.json"
    stale_starting_registry="$tmpdir/codex-stale-starting.json"
    socket="$tmpdir/live.sock"

    python3 -c 'import socket, sys, time; sock = socket.socket(socket.AF_UNIX); sock.bind(sys.argv[1]); time.sleep(10)' "$socket" &
    socket_pid="$!"
    for _ in $(seq 1 50); do
        [[ -S "$socket" ]] && break
        sleep 0.02
    done

    TMPDIR_CASE="$tmpdir" LIVE_REGISTRY="$live_registry" LIVE_OWNER_DEAD_REGISTRY="$live_owner_dead_registry" STALE_REGISTRY="$stale_registry" STALE_STARTING_REGISTRY="$stale_starting_registry" SOCKET="$socket" CODEX_UNDER_TEST="$CODEX_UNDER_TEST" bash -c '
        set -euo pipefail
        source "$CODEX_UNDER_TEST"

        REGISTRY_ROOT="$TMPDIR_CASE"
        write_registry_file "$LIVE_REGISTRY" "workspace-live" "live" "panel-live" "$$" "/tmp/tidey" "2026-06-07T00:00:00Z" "" "codex_app_server" "$SOCKET" "$$" ""
        write_registry_file "$LIVE_OWNER_DEAD_REGISTRY" "workspace-live-owner-dead" "live-owner-dead" "panel-live-owner-dead" "99999994" "/tmp/tidey" "2026-06-07T00:00:00Z" "" "codex_app_server" "$SOCKET" "$$" ""
        write_registry_file "$STALE_REGISTRY" "workspace-stale" "stale" "panel-stale" "99999999" "/tmp/tidey" "2026-06-07T00:00:00Z" "" "codex_app_server" "$TMPDIR_CASE/missing.sock" "99999998" "99999997"
        write_registry_file "$STALE_STARTING_REGISTRY" "workspace-stale-starting" "stale-starting" "panel-stale-starting" "99999996" "/tmp/tidey" "2026-06-07T00:00:00Z" "" "codex_app_server_starting" "$TMPDIR_CASE/missing-starting.sock" "99999995" ""

        cleanup_stale_app_server_registry_records

        [[ -f "$LIVE_REGISTRY" ]] || fail "live app-server registry was removed"
        [[ -f "$LIVE_OWNER_DEAD_REGISTRY" ]] || fail "live app-server registry with dead owner pid was removed"
        [[ ! -f "$STALE_REGISTRY" ]] || fail "stale app-server registry was not removed"
        [[ ! -f "$STALE_STARTING_REGISTRY" ]] || fail "stale starting app-server registry was not removed"
    '

    kill "$socket_pid" 2>/dev/null || true
    wait "$socket_pid" 2>/dev/null || true

    rm -rf "$tmpdir"
}

run_stale_app_server_registry_cleanup_test

run_app_server_runtime_selection_test() {
    local tmpdir
    local socket
    local socket_pid
    local resume_id="019eac34-764c-7893-9599-5b6000037cea"

    tmpdir="$(mktemp -d "/private/tmp/tidey-codex-selection.XXXXXX")"
    socket="$tmpdir/tidey.sock"

    python3 -c 'import socket, sys, time; sock = socket.socket(socket.AF_UNIX); sock.bind(sys.argv[1]); time.sleep(5)' "$socket" &
    socket_pid="$!"
    for _ in $(seq 1 50); do
        [[ -S "$socket" ]] && break
        sleep 0.02
    done

    TIDEY_SOCKET_PATH="$socket" TIDEY_WORKSPACE_ID="workspace-1" CODEX_UNDER_TEST="$CODEX_UNDER_TEST" bash -c '
        set -euo pipefail
        source "$CODEX_UNDER_TEST"
        if should_use_codex_app_server_runtime; then
            exit 11
        fi
        TIDEY_CODEX_APP_SERVER_ENABLE=1
        if ! should_use_codex_app_server_runtime; then
            exit 14
        fi
        if ! should_use_codex_app_server_runtime resume "'"$resume_id"'"; then
            exit 17
        fi
        if [[ "$(app_server_resume_session_id resume "'"$resume_id"'")" != "'"$resume_id"'" ]]; then
            exit 18
        fi
        if should_use_codex_app_server_runtime resume session-1; then
            exit 12
        fi
        if should_use_codex_app_server_runtime resume --last; then
            exit 19
        fi
        if should_use_codex_app_server_runtime resume "'"$resume_id"'" --help; then
            exit 20
        fi
        if should_use_codex_app_server_runtime exec echo hi; then
            exit 21
        fi
        TIDEY_CODEX_APP_SERVER_DISABLE=1
        if should_use_codex_app_server_runtime; then
            exit 13
        fi
        unset TIDEY_CODEX_APP_SERVER_DISABLE
        TIDEY_SOCKET_PATH="$TMPDIR/missing.sock"
        if should_use_codex_app_server_runtime; then
            exit 15
        fi
        TIDEY_SOCKET_PATH="'"$socket"'"
        TIDEY_WORKSPACE_ID=""
        if should_use_codex_app_server_runtime; then
            exit 16
        fi
    '

    kill "$socket_pid" 2>/dev/null || true
    wait "$socket_pid" 2>/dev/null || true

    rm -rf "$tmpdir"
}

run_app_server_runtime_selection_test

run_app_server_runtime_double_open_rejects_resume_test() {
    local tmpdir
    local fake_home
    local fake_bin
    local registry_root
    local socket
    local socket_pid
    local codex_log
    local resume_id="019eac34-764c-7893-9599-5b6000037cea"
    local registry
    local stderr_log

    tmpdir="$(mktemp -d "/private/tmp/tidey-codex-double-open.XXXXXX")"
    fake_home="$tmpdir/home"
    fake_bin="$tmpdir/bin"
    registry_root="$fake_home/Library/Application Support/Tidey Remote Bridge/agent-sessions/codex"
    socket="$tmpdir/live.sock"
    codex_log="$tmpdir/codex.log"
    registry="$registry_root/codex-$resume_id.json"
    stderr_log="$tmpdir/stderr.log"
    mkdir -p "$fake_bin" "$registry_root"

    cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_CODEX_LOG"
if [[ "${1:-}" == "--help" ]]; then
    printf '%s\n' "Usage: codex --profile <CONFIG_PROFILE_V2>"
    exit 0
fi
exit 0
FAKE_CODEX
    chmod +x "$fake_bin/codex"

    python3 -c 'import socket, sys, time; sock = socket.socket(socket.AF_UNIX); sock.bind(sys.argv[1]); time.sleep(10)' "$socket" &
    socket_pid="$!"
    for _ in $(seq 1 50); do
        [[ -S "$socket" ]] && break
        sleep 0.02
    done

    cat > "$registry" <<JSON
{"version":1,"vendor":"codex","workspace_id":"workspace-live","session_id":"$resume_id","panel_id":"panel-live","pid":99999994,"cwd":"/tmp","created_at":"2026-06-09T00:00:00Z","rollout_path":"","transcript_path":"","runtime":"codex_app_server","app_server_socket":"$socket","app_server_pid":$socket_pid}
JSON

    set +e
    HOME="$fake_home" \
        PATH="$fake_bin:/usr/bin:/bin" \
        TIDEY_CODEX_APP_SERVER_ENABLE=1 \
        TIDEY_SOCKET_PATH="$socket" \
        TIDEY_WORKSPACE_ID="workspace-1" \
        TIDEY_PANEL_ID="panel-1" \
        FAKE_CODEX_LOG="$codex_log" \
        TMPDIR="$tmpdir" \
        "$CODEX_UNDER_TEST" resume "$resume_id" 2>"$stderr_log"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "double-open resume was allowed"
    grep -q "already active" "$stderr_log" || fail "double-open resume error was not reported"
    if grep -q "app-server" "$codex_log"; then
        fail "app-server was launched for double-open resume"
    fi
    if grep -q -- "--remote" "$codex_log"; then
        fail "remote TUI was launched for double-open resume"
    fi
    [[ -f "$registry" ]] || fail "live registry was removed by double-open check"
    grep -q "\"runtime\":\"codex_app_server\"" "$registry" || fail "live registry was clobbered by double-open check"
    grep -q "\"app_server_pid\":$socket_pid" "$registry" || fail "live registry app-server pid was clobbered by double-open check"

    kill "$socket_pid" 2>/dev/null || true
    wait "$socket_pid" 2>/dev/null || true

    rm -rf "$tmpdir"
}

run_app_server_runtime_double_open_rejects_resume_test

run_app_server_runtime_plain_path_without_enable_test() {
    local tmpdir
    local fake_home
    local fake_bin
    local registry_root
    local socket
    local socket_pid
    local codex_log

    tmpdir="$(mktemp -d "/private/tmp/tidey-codex-plain-path.XXXXXX")"
    fake_home="$tmpdir/home"
    fake_bin="$tmpdir/bin"
    registry_root="$fake_home/Library/Application Support/Tidey Remote Bridge/agent-sessions/codex"
    socket="$tmpdir/tidey.sock"
    codex_log="$tmpdir/codex.log"
    mkdir -p "$fake_bin" "$registry_root"

    cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_CODEX_LOG"
if [[ "${1:-}" == "--help" ]]; then
    printf '%s\n' "Usage: codex --profile <CONFIG_PROFILE_V2>"
    exit 0
fi
exit 0
FAKE_CODEX
    chmod +x "$fake_bin/codex"

    python3 -c 'import socket, sys, time; sock = socket.socket(socket.AF_UNIX); sock.bind(sys.argv[1]); time.sleep(10)' "$socket" &
    socket_pid="$!"
    for _ in $(seq 1 50); do
        [[ -S "$socket" ]] && break
        sleep 0.02
    done

    HOME="$fake_home" \
        PATH="$fake_bin:/usr/bin:/bin" \
        TIDEY_SOCKET_PATH="$socket" \
        TIDEY_WORKSPACE_ID="workspace-1" \
        TIDEY_PANEL_ID="panel-1" \
        FAKE_CODEX_LOG="$codex_log" \
        TMPDIR="$tmpdir" \
        "$CODEX_UNDER_TEST"

    grep -q -- "--profile" "$codex_log" || fail "plain Codex path was not launched"
    if grep -q "app-server" "$codex_log"; then
        fail "app-server was launched without TIDEY_CODEX_APP_SERVER_ENABLE"
    fi
    if grep -q -- "--remote" "$codex_log"; then
        fail "remote TUI was launched without TIDEY_CODEX_APP_SERVER_ENABLE"
    fi

    kill "$socket_pid" 2>/dev/null || true
    wait "$socket_pid" 2>/dev/null || true

    rm -rf "$tmpdir"
}

run_app_server_runtime_plain_path_without_enable_test

run_app_server_runtime_launch_test() {
    local tmpdir
    local fake_home
    local fake_bin
    local registry_root
    local socket
    local socket_pid
    local codex_log
    local app_server_child_pid_file
    local remote_tui_pid_file
    local remote_tui_registry_ok_file
    local stale_registry

    tmpdir="$(mktemp -d "/private/tmp/tidey-codex-launch.XXXXXX")"
    fake_home="$tmpdir/home"
    fake_bin="$tmpdir/bin"
    registry_root="$fake_home/Library/Application Support/Tidey Remote Bridge/agent-sessions/codex"
    socket="$tmpdir/tidey.sock"
    codex_log="$tmpdir/codex.log"
    app_server_child_pid_file="$tmpdir/app-server-child.pid"
    remote_tui_pid_file="$tmpdir/remote-tui.pid"
    remote_tui_registry_ok_file="$tmpdir/remote-tui-registry.ok"
    stale_registry="$registry_root/codex-stale-session.json"
    mkdir -p "$fake_bin" "$registry_root"

    cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_CODEX_LOG"
if [[ "${1:-}" == "--help" ]]; then
    printf '%s\n' "Usage: codex --profile <CONFIG_PROFILE_V2>"
    exit 0
fi
if [[ " $* " == *" app-server "* ]]; then
    listen=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--listen" && $# -ge 2 ]]; then
            listen="$2"
            shift 2
            continue
        fi
        shift
    done
    socket_path="${listen#unix://}"
    python3 -c 'import os, socket, sys, time; path = sys.argv[1]; pid_path = sys.argv[2]; open(pid_path, "w").write(str(os.getpid())); sock = socket.socket(socket.AF_UNIX); sock.bind(path); sock.listen(1); time.sleep(20)' "$socket_path" "$FAKE_APP_SERVER_CHILD_PID_FILE"
    exit 0
fi
if [[ "$*" == *"--remote"* ]]; then
    printf '%s\n' "$$" > "$FAKE_REMOTE_TUI_PID_FILE"
    for _ in $(seq 1 50); do
        if grep -q "\"remote_tui_pid\":$$" "$FAKE_REGISTRY_ROOT"/codex-*.json 2>/dev/null; then
            printf 'ok\n' > "$FAKE_REMOTE_TUI_REGISTRY_OK_FILE"
            break
        fi
        sleep 0.02
    done
    if [[ -e "$FAKE_STALE_REGISTRY" ]]; then
        echo "stale registry survived current launch" >&2
        exit 31
    fi
    sleep 0.2
    exit 0
fi
sleep 0.2
FAKE_CODEX
    chmod +x "$fake_bin/codex"

    python3 -c 'import socket, sys, time; sock = socket.socket(socket.AF_UNIX); sock.bind(sys.argv[1]); time.sleep(10)' "$socket" &
    socket_pid="$!"
    for _ in $(seq 1 50); do
        [[ -S "$socket" ]] && break
        sleep 0.02
    done

    cat > "$stale_registry" <<'JSON'
{"version":1,"vendor":"codex","workspace_id":"stale-workspace","session_id":"stale-session","panel_id":"stale-panel","pid":99999999,"cwd":"/tmp","created_at":"2026-06-09T00:00:00Z","rollout_path":"","transcript_path":"","runtime":"codex_app_server","app_server_socket":"/tmp/missing-tidey-codex-app-server.sock","app_server_pid":99999998}
JSON

    HOME="$fake_home" \
        PATH="$fake_bin:/usr/bin:/bin" \
        TIDEY_CODEX_APP_SERVER_ENABLE=1 \
        TIDEY_SOCKET_PATH="$socket" \
        TIDEY_WORKSPACE_ID="workspace-1" \
        TIDEY_PANEL_ID="panel-1" \
        FAKE_CODEX_LOG="$codex_log" \
        FAKE_APP_SERVER_CHILD_PID_FILE="$app_server_child_pid_file" \
        FAKE_REMOTE_TUI_PID_FILE="$remote_tui_pid_file" \
        FAKE_REMOTE_TUI_REGISTRY_OK_FILE="$remote_tui_registry_ok_file" \
        FAKE_REGISTRY_ROOT="$registry_root" \
        FAKE_STALE_REGISTRY="$stale_registry" \
        TMPDIR="$tmpdir" \
        "$CODEX_UNDER_TEST"

    [[ -z "$(find "$registry_root" -name "codex-*.json" -print -quit)" ]] || fail "app-server registry file was not cleaned up"
    grep -q "app-server" "$codex_log" || fail "app-server was not launched"
    grep -q -- "--remote" "$codex_log" || fail "remote TUI was not launched"
    [[ -f "$remote_tui_pid_file" ]] || fail "remote TUI pid was not recorded"
    [[ -f "$remote_tui_registry_ok_file" ]] || fail "remote TUI pid was not written to registry"
    [[ -f "$app_server_child_pid_file" ]] || fail "app-server child pid was not recorded"
    app_server_child_pid="$(cat "$app_server_child_pid_file")"
    for _ in $(seq 1 50); do
        child_state="$(ps -o stat= -p "$app_server_child_pid" 2>/dev/null | tr -d " " || true)"
        if [[ -z "$child_state" || "$child_state" == Z* ]]; then
            break
        fi
        sleep 0.02
    done
    child_state="$(ps -o stat= -p "$app_server_child_pid" 2>/dev/null | tr -d " " || true)"
    if [[ -n "$child_state" && "$child_state" != Z* ]]; then
        kill "$app_server_child_pid" 2>/dev/null || true
        fail "app-server child process was not cleaned up: state=$child_state"
    fi

    python3 - "$codex_log" <<'PY'
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_text().splitlines()
app_server_lines = [line for line in lines if line.startswith("app-server ")]
remote_lines = [line for line in lines if "--remote" in line]

assert app_server_lines, "app-server was not launched"
assert remote_lines, "remote TUI was not launched"
assert all("--profile " not in line and "--profile-v2 " not in line for line in app_server_lines), app_server_lines
assert all("--profile " not in line and "--profile-v2 " not in line for line in remote_lines), remote_lines
PY

    kill "$socket_pid" 2>/dev/null || true
    wait "$socket_pid" 2>/dev/null || true

    rm -rf "$tmpdir"
}

run_app_server_runtime_launch_test

run_app_server_runtime_resume_launch_test() {
    local tmpdir
    local fake_home
    local fake_bin
    local registry_root
    local socket
    local socket_pid
    local codex_log
    local app_server_child_pid_file
    local remote_tui_registry_ok_file
    local resume_id="019eac34-764c-7893-9599-5b6000037cea"
    local resume_rollout_path

    tmpdir="$(mktemp -d "/private/tmp/tidey-codex-resume-launch.XXXXXX")"
    fake_home="$tmpdir/home"
    fake_bin="$tmpdir/bin"
    registry_root="$fake_home/Library/Application Support/Tidey Remote Bridge/agent-sessions/codex"
    socket="$tmpdir/tidey.sock"
    codex_log="$tmpdir/codex.log"
    app_server_child_pid_file="$tmpdir/app-server-child.pid"
    remote_tui_registry_ok_file="$tmpdir/remote-tui-registry.ok"
    resume_rollout_path="$fake_home/.codex/sessions/2026/06/09/rollout-2026-06-09T22-00-00-$resume_id.jsonl"
    mkdir -p "$fake_bin" "$registry_root"
    mkdir -p "$(dirname "$resume_rollout_path")"
    printf '[]\n' > "$resume_rollout_path"

    cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_CODEX_LOG"
if [[ "${1:-}" == "--help" ]]; then
    printf '%s\n' "Usage: codex --profile <CONFIG_PROFILE_V2>"
    exit 0
fi
if [[ " $* " == *" app-server "* ]]; then
    listen=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--listen" && $# -ge 2 ]]; then
            listen="$2"
            shift 2
            continue
        fi
        shift
    done
    socket_path="${listen#unix://}"
    python3 -c 'import os, socket, sys, time; path = sys.argv[1]; pid_path = sys.argv[2]; open(pid_path, "w").write(str(os.getpid())); sock = socket.socket(socket.AF_UNIX); sock.bind(path); sock.listen(1); time.sleep(20)' "$socket_path" "$FAKE_APP_SERVER_CHILD_PID_FILE"
    exit 0
fi
if [[ "$*" == *"--remote"* ]]; then
    for _ in $(seq 1 50); do
        if grep -Fq "\"session_id\":\"$FAKE_RESUME_ID\"" "$FAKE_REGISTRY_ROOT"/codex-"$FAKE_RESUME_ID".json 2>/dev/null \
            && grep -Fq "\"remote_tui_pid\":$$" "$FAKE_REGISTRY_ROOT"/codex-"$FAKE_RESUME_ID".json 2>/dev/null \
            && grep -Fq "\"rollout_path\":\"$FAKE_RESUME_ROLLOUT_PATH\"" "$FAKE_REGISTRY_ROOT"/codex-"$FAKE_RESUME_ID".json 2>/dev/null; then
            printf 'ok\n' > "$FAKE_REMOTE_TUI_REGISTRY_OK_FILE"
            break
        fi
        sleep 0.02
    done
    sleep 0.2
    exit 0
fi
sleep 0.2
FAKE_CODEX
    chmod +x "$fake_bin/codex"

    python3 -c 'import socket, sys, time; sock = socket.socket(socket.AF_UNIX); sock.bind(sys.argv[1]); time.sleep(10)' "$socket" &
    socket_pid="$!"
    for _ in $(seq 1 50); do
        [[ -S "$socket" ]] && break
        sleep 0.02
    done

    HOME="$fake_home" \
        CODEX_HOME="$fake_home/.codex" \
        PATH="$fake_bin:/usr/bin:/bin" \
        TIDEY_CODEX_APP_SERVER_ENABLE=1 \
        TIDEY_SOCKET_PATH="$socket" \
        TIDEY_WORKSPACE_ID="workspace-1" \
        TIDEY_PANEL_ID="panel-1" \
        FAKE_CODEX_LOG="$codex_log" \
        FAKE_APP_SERVER_CHILD_PID_FILE="$app_server_child_pid_file" \
        FAKE_REMOTE_TUI_REGISTRY_OK_FILE="$remote_tui_registry_ok_file" \
        FAKE_REGISTRY_ROOT="$registry_root" \
        FAKE_RESUME_ID="$resume_id" \
        FAKE_RESUME_ROLLOUT_PATH="$resume_rollout_path" \
        TMPDIR="$tmpdir" \
        "$CODEX_UNDER_TEST" resume "$resume_id"

    [[ -z "$(find "$registry_root" -name "codex-*.json" -print -quit)" ]] || fail "resume app-server registry file was not cleaned up"
    grep -q "app-server" "$codex_log" || fail "resume app-server was not launched"
    grep -q -- "--remote .* resume $resume_id" "$codex_log" || fail "resume remote TUI was not launched with resume id"
    [[ -f "$remote_tui_registry_ok_file" ]] || fail "resume session id and rollout path were not written to registry"
    [[ -f "$app_server_child_pid_file" ]] || fail "resume app-server child pid was not recorded"
    app_server_child_pid="$(cat "$app_server_child_pid_file")"
    for _ in $(seq 1 50); do
        child_state="$(ps -o stat= -p "$app_server_child_pid" 2>/dev/null | tr -d " " || true)"
        if [[ -z "$child_state" || "$child_state" == Z* ]]; then
            break
        fi
        sleep 0.02
    done
    child_state="$(ps -o stat= -p "$app_server_child_pid" 2>/dev/null | tr -d " " || true)"
    if [[ -n "$child_state" && "$child_state" != Z* ]]; then
        kill "$app_server_child_pid" 2>/dev/null || true
        fail "resume app-server child process was not cleaned up: state=$child_state"
    fi

    kill "$socket_pid" 2>/dev/null || true
    wait "$socket_pid" 2>/dev/null || true

    rm -rf "$tmpdir"
}

run_app_server_runtime_resume_launch_test

run_app_server_runtime_resume_failure_cleanup_test() {
    local tmpdir
    local fake_home
    local fake_bin
    local registry_root
    local socket
    local socket_pid
    local codex_log
    local app_server_child_pid_file
    local resume_id="019eac34-764c-7893-9599-5b6000037cea"

    tmpdir="$(mktemp -d "/private/tmp/tidey-codex-resume-failure.XXXXXX")"
    fake_home="$tmpdir/home"
    fake_bin="$tmpdir/bin"
    registry_root="$fake_home/Library/Application Support/Tidey Remote Bridge/agent-sessions/codex"
    socket="$tmpdir/tidey.sock"
    codex_log="$tmpdir/codex.log"
    app_server_child_pid_file="$tmpdir/app-server-child.pid"
    mkdir -p "$fake_bin" "$registry_root"

    cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_CODEX_LOG"
if [[ "${1:-}" == "--help" ]]; then
    printf '%s\n' "Usage: codex --profile <CONFIG_PROFILE_V2>"
    exit 0
fi
if [[ " $* " == *" app-server "* ]]; then
    listen=""
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--listen" && $# -ge 2 ]]; then
            listen="$2"
            shift 2
            continue
        fi
        shift
    done
    socket_path="${listen#unix://}"
    python3 -c 'import os, socket, sys, time; path = sys.argv[1]; pid_path = sys.argv[2]; open(pid_path, "w").write(str(os.getpid())); sock = socket.socket(socket.AF_UNIX); sock.bind(path); sock.listen(1); time.sleep(20)' "$socket_path" "$FAKE_APP_SERVER_CHILD_PID_FILE"
    exit 0
fi
if [[ "$*" == *"--remote"* ]]; then
    exit 42
fi
exit 0
FAKE_CODEX
    chmod +x "$fake_bin/codex"

    python3 -c 'import socket, sys, time; sock = socket.socket(socket.AF_UNIX); sock.bind(sys.argv[1]); time.sleep(10)' "$socket" &
    socket_pid="$!"
    for _ in $(seq 1 50); do
        [[ -S "$socket" ]] && break
        sleep 0.02
    done

    set +e
    HOME="$fake_home" \
        PATH="$fake_bin:/usr/bin:/bin" \
        TIDEY_CODEX_APP_SERVER_ENABLE=1 \
        TIDEY_SOCKET_PATH="$socket" \
        TIDEY_WORKSPACE_ID="workspace-1" \
        TIDEY_PANEL_ID="panel-1" \
        FAKE_CODEX_LOG="$codex_log" \
        FAKE_APP_SERVER_CHILD_PID_FILE="$app_server_child_pid_file" \
        TMPDIR="$tmpdir" \
        "$CODEX_UNDER_TEST" resume "$resume_id"
    status=$?
    set -e

    [[ "$status" == "42" ]] || fail "resume remote TUI failure status was not propagated"
    [[ -z "$(find "$registry_root" -name "codex-*.json" -print -quit)" ]] || fail "failed resume registry file was not cleaned up"
    [[ -f "$app_server_child_pid_file" ]] || fail "failed resume app-server child pid was not recorded"
    app_server_child_pid="$(cat "$app_server_child_pid_file")"
    for _ in $(seq 1 50); do
        child_state="$(ps -o stat= -p "$app_server_child_pid" 2>/dev/null | tr -d " " || true)"
        if [[ -z "$child_state" || "$child_state" == Z* ]]; then
            break
        fi
        sleep 0.02
    done
    child_state="$(ps -o stat= -p "$app_server_child_pid" 2>/dev/null | tr -d " " || true)"
    if [[ -n "$child_state" && "$child_state" != Z* ]]; then
        kill "$app_server_child_pid" 2>/dev/null || true
        fail "failed resume app-server child process was not cleaned up: state=$child_state"
    fi

    kill "$socket_pid" 2>/dev/null || true
    wait "$socket_pid" 2>/dev/null || true

    rm -rf "$tmpdir"
}

run_app_server_runtime_resume_failure_cleanup_test

echo "PASS"
