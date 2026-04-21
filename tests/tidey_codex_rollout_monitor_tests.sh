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

echo "PASS"
