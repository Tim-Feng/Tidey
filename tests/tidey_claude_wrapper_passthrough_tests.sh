#!/usr/bin/env bash

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$REPO/Resources/bin/claude"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tidey-claude-passthrough.XXXXXX")"
MOCK_BIN="$TMP_ROOT/mock-bin"
REAL_BIN="$TMP_ROOT/real-bin"
SOCKET_PATH="$TMP_ROOT/tidey.sock"
SOCKET_PID=""

cleanup() {
    if [[ -n "$SOCKET_PID" ]]; then
        kill "$SOCKET_PID" 2>/dev/null || true
        wait "$SOCKET_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$MOCK_BIN" "$REAL_BIN"

cat > "$MOCK_BIN/tmux" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  "show-options -p -v -t %42 @tidey_workspace_id")
    count=0
    if [[ -f "${TIDEY_TEST_IDENTITY_COUNT_FILE:?}" ]]; then
        count="$(<"$TIDEY_TEST_IDENTITY_COUNT_FILE")"
    fi
    count=$((count + 1))
    printf '%s' "$count" > "$TIDEY_TEST_IDENTITY_COUNT_FILE"
    if [[ "$count" -gt "${TIDEY_TEST_IDENTITY_READY_AFTER:-999999}" ]]; then
        : > "${TIDEY_TEST_WAIT_MARKER:?}"
        printf '%s\n' workspace-delayed
    fi
    ;;
  "show-options -p -v -t %42 @tidey_panel_id")
    count=0
    if [[ -f "${TIDEY_TEST_IDENTITY_COUNT_FILE:?}" ]]; then
        count="$(<"$TIDEY_TEST_IDENTITY_COUNT_FILE")"
    fi
    if [[ "$count" -gt "${TIDEY_TEST_IDENTITY_READY_AFTER:-999999}" ]]; then
        printf '%s\n' panel-delayed
    fi
    ;;
  "show-options -p -v -t %42 @tidey_socket_path")
    printf '%s\n' "${TIDEY_TEST_SOCKET_PATH:?}"
    ;;
  "show-options -p -v -t %42 @tidey_bin_dir")
    printf '%s\n' "${TIDEY_TEST_TIDEY_BIN_DIR:?}"
    ;;
  *)
    exit 1
    ;;
esac
SH

cat > "$REAL_BIN/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${TIDEY_TEST_REAL_CLAUDE_LOG:?}"
SH

chmod +x "$MOCK_BIN/tmux" "$REAL_BIN/claude"

python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(30)' "$SOCKET_PATH" >/dev/null 2>&1 &
SOCKET_PID=$!
for _ in $(seq 1 100); do
    [[ -S "$SOCKET_PATH" ]] && break
    sleep 0.01
done
[[ -S "$SOCKET_PATH" ]] || fail "socket fixture did not start"

for subcommand in mcp config api-key; do
    identity_count_file="$TMP_ROOT/$subcommand.identity-count"
    wait_marker="$TMP_ROOT/$subcommand.wait-entered"
    real_claude_log="$TMP_ROOT/$subcommand.real-claude.log"
    printf '0' > "$identity_count_file"

    env -u TIDEY_WORKSPACE_ID -u TIDEY_PANEL_ID \
        HOME="$TMP_ROOT/home" \
        PATH="$MOCK_BIN:$REAL_BIN:/usr/bin:/bin" \
        TMUX=/tmp/tmux-test,1,0 \
        TMUX_PANE=%42 \
        TIDEY_SOCKET_PATH="$SOCKET_PATH" \
        TIDEY_TEST_IDENTITY_COUNT_FILE="$identity_count_file" \
        TIDEY_TEST_WAIT_MARKER="$wait_marker" \
        TIDEY_TEST_SOCKET_PATH="$SOCKET_PATH" \
        TIDEY_TEST_TIDEY_BIN_DIR="$(dirname "$WRAPPER")" \
        TIDEY_TEST_REAL_CLAUDE_LOG="$real_claude_log" \
        TIDEY_TMUX_IDENTITY_WAIT_ATTEMPTS=1 \
        TIDEY_TMUX_IDENTITY_WAIT_INTERVAL=0 \
        "$WRAPPER" "$subcommand" sentinel

    expected_args="$TMP_ROOT/$subcommand.expected-args"
    printf '%s\n' "$subcommand" sentinel > "$expected_args"
    cmp -s "$expected_args" "$real_claude_log" ||
        fail "$subcommand did not pass through unchanged"
    [[ ! -e "$wait_marker" ]] ||
        fail "$subcommand entered the late pane-identity wait"
    [[ "$(<"$identity_count_file")" == "1" ]] ||
        fail "$subcommand performed more than the initial tmux context hydration"
done

# A normal interactive invocation must take the opposite branch: wait until
# Tidey projects the delayed pane identity, then launch Claude with the full
# typed hook settings. This covers the wrapper wiring itself; the focused
# helper/dispatch tests cover the sourced implementations independently.
identity_count_file="$TMP_ROOT/interactive.identity-count"
wait_marker="$TMP_ROOT/interactive.wait-entered"
real_claude_log="$TMP_ROOT/interactive.real-claude.log"
printf '0' > "$identity_count_file"

env -u TIDEY_WORKSPACE_ID -u TIDEY_PANEL_ID \
    HOME="$TMP_ROOT/home" \
    PATH="$MOCK_BIN:$REAL_BIN:/usr/bin:/bin" \
    TMUX=/tmp/tmux-test,1,0 \
    TMUX_PANE=%42 \
    TIDEY_SOCKET_PATH="$SOCKET_PATH" \
    TIDEY_TEST_IDENTITY_COUNT_FILE="$identity_count_file" \
    TIDEY_TEST_IDENTITY_READY_AFTER=2 \
    TIDEY_TEST_WAIT_MARKER="$wait_marker" \
    TIDEY_TEST_SOCKET_PATH="$SOCKET_PATH" \
    TIDEY_TEST_TIDEY_BIN_DIR="$(dirname "$WRAPPER")" \
    TIDEY_TEST_REAL_CLAUDE_LOG="$real_claude_log" \
    TIDEY_TMUX_IDENTITY_WAIT_ATTEMPTS=3 \
    TIDEY_TMUX_IDENTITY_WAIT_INTERVAL=0 \
    "$WRAPPER" interactive-sentinel

[[ -e "$wait_marker" ]] ||
    fail "interactive invocation did not wait for delayed pane identity"
[[ "$(<"$identity_count_file")" -gt 1 ]] ||
    fail "interactive invocation did not retry pane identity hydration"

claude_args="$(paste -sd ' ' "$real_claude_log")"
[[ "$claude_args" == --settings\ * ]] ||
    fail "interactive invocation did not inject --settings"
hook_epoch="$(printf '%s\n' "$claude_args" | grep -Eo '[0-9]+-[0-9]{10,}' | head -n 1 || true)"
if [[ -z "$hook_epoch" ]]; then
    fail "interactive hook settings did not include a numeric wrapper epoch"
fi
hook_epoch_timestamp="${hook_epoch##*-}"
[[ "${#hook_epoch_timestamp}" -ge 19 ]] ||
    fail "wrapper epoch timestamp lacks nanosecond precision: $hook_epoch"
for expected in \
    '"matcher":"permission_prompt"' \
    '"matcher":"idle_prompt"' \
    '"PermissionRequest"' \
    '"PostToolUse"' \
    'notification-permission' \
    'notification-idle' \
    'permission-request' \
    'post-tool-use' \
    'claude-hook-dispatch'; do
    [[ "$claude_args" == *"$expected"* ]] ||
        fail "interactive hook settings missing $expected"
done
[[ "$claude_args" == *" --session-id "* ]] ||
    fail "interactive invocation did not pass its generated session id"
[[ "$claude_args" == *" interactive-sentinel" ]] ||
    fail "interactive invocation did not preserve the original argument"

mcp_flag_count="$(grep -c -x -- '--mcp-config' "$real_claude_log" || true)"
[[ "$mcp_flag_count" == "1" ]] ||
    fail "interactive invocation did not inject exactly one --mcp-config flag"
mcp_flag_line="$(grep -n -x -- '--mcp-config' "$real_claude_log" | cut -d: -f1)"
mcp_config="$(sed -n "$((mcp_flag_line + 1))p" "$real_claude_log")"
[[ -n "$mcp_config" ]] ||
    fail "interactive invocation did not pass the MCP JSON as the next argv item"

python3 - "$mcp_config" "$SOCKET_PATH" "$(dirname "$WRAPPER")/tidey-browser-mcp" <<'PY' ||
import json
import sys

config = json.loads(sys.argv[1])
server = config["mcpServers"]["tidey_browser"]
assert server == {
    "type": "stdio",
    "command": sys.argv[3],
    "args": [],
    "env": {
        "TIDEY_SOCKET_PATH": sys.argv[2],
        "TIDEY_WORKSPACE_ID": "workspace-delayed",
    },
}
PY
    fail "interactive invocation passed an invalid Tidey Browser MCP config"

if grep -q -x -- '--strict-mcp-config' "$real_claude_log"; then
    fail "interactive invocation unexpectedly isolated Claude from other MCP configs"
fi

# A live Tidey socket alone is insufficient. Without a workspace identity,
# Claude still gets Tidey's hooks but must not get a browser server that would
# fail closed on every operation.
no_workspace_log="$TMP_ROOT/no-workspace.real-claude.log"
env -u TIDEY_WORKSPACE_ID -u TIDEY_PANEL_ID -u TMUX -u TMUX_PANE \
    HOME="$TMP_ROOT/home-no-workspace" \
    PATH="$REAL_BIN:/usr/bin:/bin" \
    TIDEY_SOCKET_PATH="$SOCKET_PATH" \
    TIDEY_TEST_REAL_CLAUDE_LOG="$no_workspace_log" \
    "$WRAPPER" no-workspace-sentinel

grep -q -x -- '--settings' "$no_workspace_log" ||
    fail "live-socket invocation without a workspace lost Tidey's hooks"
if grep -q -x -- '--mcp-config' "$no_workspace_log"; then
    fail "live-socket invocation without a workspace injected browser MCP"
fi
grep -q -x -- 'no-workspace-sentinel' "$no_workspace_log" ||
    fail "live-socket invocation without a workspace lost the original argument"

echo "PASS"
