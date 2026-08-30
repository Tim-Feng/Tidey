#!/usr/bin/env bash

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tidey-dev-agent-wrapper.XXXXXX")"
MOCK_BIN="$TMP_ROOT/mock-bin"
REAL_BIN="$TMP_ROOT/real-bin"
WRAPPER_BIN="$TMP_ROOT/wrapper-bin"
TMUX_LOG="$TMP_ROOT/tmux.log"
TIDEY_LOG="$TMP_ROOT/tidey.log"

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$MOCK_BIN" "$REAL_BIN" "$WRAPPER_BIN" "$TMP_ROOT/home"

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
    for arg in "$@"; do
        printf 'arg=%s\n' "$arg"
    done
    printf 'hooks=%s\n' "${TIDEY_CODEX_HOOKS_ENABLED:-}"
    printf 'codex_home=%s\n' "${CODEX_HOME:-}"
} > "${DEV_WRAPPER_REAL_LOG:?}"
SH

cp "$REPO/Resources/bin/codex" "$WRAPPER_BIN/codex"
cp "$REPO/Resources/bin/codex-hook-dispatch" "$WRAPPER_BIN/codex-hook-dispatch"
cp "$REPO/Resources/bin/tidey-tmux-pane-identity" "$WRAPPER_BIN/tidey-tmux-pane-identity"
cat > "$WRAPPER_BIN/tidey" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${DEV_WRAPPER_TIDEY_LOG:?}"
SH

chmod +x "$MOCK_BIN/tmux" "$REAL_BIN/claude" "$REAL_BIN/codex" \
    "$WRAPPER_BIN/codex" "$WRAPPER_BIN/codex-hook-dispatch" \
    "$WRAPPER_BIN/tidey-tmux-pane-identity" "$WRAPPER_BIN/tidey"

mkdir -p "$TMP_ROOT/home/.codex"
python3 - "$TMP_ROOT/home/.codex/hooks.json" "$WRAPPER_BIN/codex-hook-dispatch" <<'PY'
from pathlib import Path
import json
import sys

hooks_path = Path(sys.argv[1])
dispatch = sys.argv[2]

def quoted(command: str) -> str:
    return "'" + command.replace("'", "'\\''") + "'"

hooks_path.write_text(json.dumps({
    "hooks": {
        "SessionStart": [
            {"hooks": [{"type": "command", "command": "/tmp/untrusted-session-hook"}]},
            {"hooks": [{"type": "command", "command": f"{quoted(dispatch)} session-start", "timeout": 10}]},
        ],
        "UserPromptSubmit": [
            {"hooks": [{"type": "command", "command": f"{quoted(dispatch)} user-prompt-submit", "timeout": 10}]},
        ],
        "Stop": [
            {"hooks": [{"type": "command", "command": "/tmp/untrusted-stop-hook"}]},
            {"hooks": [{"type": "command", "command": f"{quoted(dispatch)} stop", "timeout": 10}]},
        ],
    }
}, indent=2) + "\n")
PY

for vendor in claude codex; do
    real_log="$TMP_ROOT/$vendor.real.log"
    wrapper="$REPO/Resources/bin/$vendor"
    if [[ "$vendor" == "codex" ]]; then
        wrapper="$WRAPPER_BIN/codex"
    fi
    rm -f "$TMUX_LOG"
    rm -f "$TIDEY_LOG"
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
        DEV_WRAPPER_TIDEY_LOG="$TIDEY_LOG" \
        DEV_WRAPPER_REAL_LOG="$real_log" \
        "$wrapper" --sentinel "two words"

    if [[ "$vendor" == "claude" ]]; then
        grep -qx 'args=<--sentinel><two words>' "$real_log" ||
            fail "$vendor did not pass arguments through unchanged"
    else
        grep -q '^args=.*<--sentinel><two words>$' "$real_log" ||
            fail "$vendor did not preserve user arguments after isolated hook configuration"
    fi
    [[ ! -e "$TMUX_LOG" ]] ||
        fail "$vendor read production tmux state in the Development sandbox"
done

grep -qx 'codex-hook session-start' "$TIDEY_LOG" ||
    fail "Codex Development passthrough did not report its initial idle edge"
grep -qx 'hooks=1' "$TMP_ROOT/codex.real.log" ||
    fail "Codex Development passthrough did not enable isolated status hooks"
grep -qx 'arg=features.hooks=true' "$TMP_ROOT/codex.real.log" ||
    fail "Codex Development passthrough did not enable the Codex hooks feature"
hook_state="$(sed -n 's/^arg=\(hooks\.state=.*\)$/\1/p' "$TMP_ROOT/codex.real.log")"
[[ -n "$hook_state" ]] ||
    fail "Codex Development passthrough did not inject trusted Tidey hook state"
for event in session_start user_prompt_submit stop; do
    [[ "$hook_state" == *":$event:"* ]] ||
        fail "Codex Development hook state omitted $event"
done
hash_count="$(printf '%s\n' "$hook_state" | grep -oE 'trusted_hash="sha256:[0-9a-f]{64}"' | wc -l | tr -d ' ')"
[[ "$hash_count" == "3" ]] ||
    fail "Codex Development hook state did not trust exactly three Tidey hooks"
[[ "$hook_state" != *untrusted* ]] ||
    fail "Codex Development hook state trusted an unrelated user hook"
grep -qx 'codex_home=' "$TMP_ROOT/codex.real.log" ||
    fail "Codex Development passthrough replaced CODEX_HOME"
[[ ! -e "$TMP_ROOT/home/Library/Application Support/Tidey Remote Bridge" ]] ||
    fail "Development wrappers wrote production Remote Bridge state"

echo "PASS"
