#!/usr/bin/env bash

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tidey-dev-agent-wrapper.XXXXXX")"
MOCK_BIN="$TMP_ROOT/mock-bin"
REAL_BIN="$TMP_ROOT/real-bin"
TMUX_LOG="$TMP_ROOT/tmux.log"

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$MOCK_BIN" "$REAL_BIN" "$TMP_ROOT/home"

cat > "$MOCK_BIN/tmux" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${DEV_WRAPPER_TMUX_LOG:?}"
exit 91
SH

cat > "$REAL_BIN/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'args='
    printf '<%s>' "$@"
    printf '\n'
} > "${DEV_WRAPPER_REAL_LOG:?}"
SH

cat > "$REAL_BIN/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'args='
    printf '<%s>' "$@"
    printf '\n'
    printf 'hooks=%s\n' "${TIDEY_CODEX_HOOKS_ENABLED:-}"
    printf 'codex_home=%s\n' "${CODEX_HOME:-}"
} > "${DEV_WRAPPER_REAL_LOG:?}"
SH

chmod +x "$MOCK_BIN/tmux" "$REAL_BIN/claude" "$REAL_BIN/codex"

for vendor in claude codex; do
    real_log="$TMP_ROOT/$vendor.real.log"
    rm -f "$TMUX_LOG"
    env -u CODEX_HOME -u TIDEY_CODEX_HOOKS_ENABLED \
        HOME="$TMP_ROOT/home" \
        PATH="$MOCK_BIN:$REAL_BIN:/usr/bin:/bin" \
        TMUX=/tmp/production-tmux,1,0 \
        TMUX_PANE=%42 \
        TIDEY_DEV_SANDBOX=1 \
        TIDEY_SOCKET_PATH=/tmp/production.sock \
        TIDEY_WORKSPACE_ID=production-workspace \
        TIDEY_PANEL_ID=production-panel \
        DEV_WRAPPER_TMUX_LOG="$TMUX_LOG" \
        DEV_WRAPPER_REAL_LOG="$real_log" \
        "$REPO/Resources/bin/$vendor" --sentinel "two words"

    grep -qx 'args=<--sentinel><two words>' "$real_log" ||
        fail "$vendor did not pass arguments through unchanged"
    [[ ! -e "$TMUX_LOG" ]] ||
        fail "$vendor read production tmux state in the Development sandbox"
done

grep -qx 'hooks=' "$TMP_ROOT/codex.real.log" ||
    fail "Codex Development passthrough enabled Tidey hooks"
grep -qx 'codex_home=' "$TMP_ROOT/codex.real.log" ||
    fail "Codex Development passthrough replaced CODEX_HOME"
[[ ! -e "$TMP_ROOT/home/Library/Application Support/Tidey Remote Bridge" ]] ||
    fail "Development wrappers wrote production Remote Bridge state"

echo "PASS"
