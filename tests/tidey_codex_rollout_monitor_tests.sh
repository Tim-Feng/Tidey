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
        mkdir -p "$real_home"
        printf "%s\n" "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"/tmp/user-hook\"}]}]}}" > "$real_home/hooks.json"

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

if "/tmp/user-hook" not in json.dumps(hooks_root):
    raise SystemExit("existing user hook was not preserved")

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

echo "PASS"
