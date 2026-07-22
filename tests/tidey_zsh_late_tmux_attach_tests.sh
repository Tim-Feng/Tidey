#!/usr/bin/env bash

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INTEGRATION="$REPO/Resources/shell_integration/iterm2_shell_integration.zsh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tidey-zsh-late-attach.XXXXXX")"
MOCK_BIN="$TMP_ROOT/mock-bin"
REAL_BIN="$TMP_ROOT/real-bin"
TIDEY_BIN="$TMP_ROOT/tidey-bin"
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

mkdir -p "$MOCK_BIN" "$REAL_BIN" "$TIDEY_BIN"

cat > "$MOCK_BIN/tmux" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

mode="${TIDEY_TMUX_TEST_MODE:-}"
case "$mode:$*" in
  "attached:show-options -p -v -t %42 @tidey_workspace_id")
    printf 'workspace-late\n'
    ;;
  "attached:show-options -p -v -t %42 @tidey_panel_id")
    printf 'panel-late\n'
    ;;
  "attached:show-options -p -v -t %42 @tidey_socket_path")
    printf '%s\n' "${TIDEY_TEST_SOCKET_PATH:?}"
    ;;
  "attached:show-options -p -v -t %42 @tidey_bin_dir")
    printf '%s\n' "${TIDEY_TEST_BIN_DIR:?}"
    ;;
  "session-attached:show-options -p -v -t %42 @tidey_workspace_id"|\
  "session-attached:show-options -p -v -t %42 @tidey_panel_id"|\
  "session-attached:show-options -p -v -t %42 @tidey_socket_path"|\
  "session-attached:show-options -p -v -t %42 @tidey_bin_dir")
    exit 1
    ;;
  "session-attached:show-environment -t %42 TIDEY_SOCKET_PATH")
    printf 'TIDEY_SOCKET_PATH=%s\n' "${TIDEY_TEST_SOCKET_PATH:?}"
    ;;
  "session-attached:show-environment -t %42 TIDEY_BIN_DIR")
    printf 'TIDEY_BIN_DIR=%s\n' "${TIDEY_TEST_BIN_DIR:?}"
    ;;
  *)
    exit 1
    ;;
esac
SH

cat > "$REAL_BIN/codex" <<'SH'
#!/usr/bin/env bash
printf 'REAL-CODEX\n'
SH

cat > "$TIDEY_BIN/codex" <<'SH'
#!/usr/bin/env bash
printf 'TIDEY-WRAPPER\n'
SH

chmod +x "$MOCK_BIN/tmux" "$REAL_BIN/codex" "$TIDEY_BIN/codex"

python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(60)' "$SOCKET_PATH" &
SOCKET_PID=$!
for _ in $(seq 1 100); do
    [[ -S "$SOCKET_PATH" ]] && break
    sleep 0.01
done
[[ -S "$SOCKET_PATH" ]] || { echo "FAIL: socket fixture did not start" >&2; exit 1; }

export TIDEY_TEST_SOCKET_PATH="$SOCKET_PATH"
export TIDEY_TEST_BIN_DIR="$TIDEY_BIN"
export TIDEY_INTEGRATION_UNDER_TEST="$INTEGRATION"
export TIDEY_TEST_INITIAL_PATH="$MOCK_BIN:$REAL_BIN:/usr/bin:/bin:/usr/sbin:/sbin"

expect <<'EXPECT'
set timeout 10
proc expect_or_fail {pattern failure_code} {
    expect {
        -re $pattern { return }
        timeout { exit $failure_code }
        eof { exit $failure_code }
    }
}
spawn env -u TIDEY_SOCKET_PATH -u TIDEY_WORKSPACE_ID -u TIDEY_PANEL_ID -u TIDEY_BIN_DIR TIDEY_TMUX_TEST_MODE=detached TMUX=/tmp/tmux-test,1,0 TMUX_PANE=%42 TERM=screen-256color TERM_PROGRAM=Termius PATH=$env(TIDEY_TEST_INITIAL_PATH) zsh -dfi
expect_or_fail {% } 10
send -- "source \"$env(TIDEY_INTEGRATION_UNDER_TEST)\"\r"
expect_or_fail {% } 11
send -- "command -v codex\r"
expect_or_fail {real-bin/codex} 12
expect_or_fail {% } 13
send -- "export TIDEY_TMUX_TEST_MODE=session-attached\r"
expect_or_fail {% } 14
send -- "codex\r"
expect_or_fail {TIDEY-WRAPPER} 15
expect_or_fail {% } 16
send -- "print -r -- \"\${TIDEY_WORKSPACE_ID-unset}|\${TIDEY_PANEL_ID-unset}|\$TIDEY_SOCKET_PATH|\$TIDEY_BIN_DIR\"\r"
expect_or_fail "unset\\|unset\\|$env(TIDEY_TEST_SOCKET_PATH)\\|$env(TIDEY_TEST_BIN_DIR)" 17
expect_or_fail {% } 18
send -- "export TIDEY_TMUX_TEST_MODE=attached\r"
expect_or_fail {% } 19
send -- "print -r -- \"\$TIDEY_WORKSPACE_ID|\$TIDEY_PANEL_ID|\$TIDEY_SOCKET_PATH|\$TIDEY_BIN_DIR\"\r"
expect_or_fail "workspace-late\\|panel-late\\|$env(TIDEY_TEST_SOCKET_PATH)\\|$env(TIDEY_TEST_BIN_DIR)" 20
expect_or_fail {% } 21
send -- "exit\r"
expect {
    eof {}
    timeout { exit 22 }
}
EXPECT

echo "PASS"
