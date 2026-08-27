#!/usr/bin/env bash

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$REPO/tools/run-development-sandbox.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tidey-dev-sandbox.XXXXXX")"
DEV_APP="$TMP_ROOT/Tidey Dev.app"
PROD_APP="$TMP_ROOT/Tidey.app"
LOG_FILE="$TMP_ROOT/launch.log"

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

make_fixture() {
    local app_path="$1"
    local bundle_id="$2"
    local executable_name="$3"

    mkdir -p "$app_path/Contents/MacOS"
    plutil -create xml1 "$app_path/Contents/Info.plist"
    plutil -insert CFBundleIdentifier -string "$bundle_id" "$app_path/Contents/Info.plist"
    plutil -insert CFBundleExecutable -string "$executable_name" "$app_path/Contents/Info.plist"
    cp "$TMP_ROOT/fake-tidey" "$app_path/Contents/MacOS/$executable_name"
    chmod +x "$app_path/Contents/MacOS/$executable_name"
}

cat > "$TMP_ROOT/fake-tidey" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'args='
    printf '<%s>' "$@"
    printf '\n'
    printf 'TIDEY_DEV_SANDBOX=%s\n' "${TIDEY_DEV_SANDBOX:-}"
    printf 'TMUX=%s\n' "${TMUX:-}"
    printf 'TMUX_PANE=%s\n' "${TMUX_PANE:-}"
    printf '__CFBundleIdentifier=%s\n' "${__CFBundleIdentifier:-}"
    printf 'TIDEY_SOCKET_PATH=%s\n' "${TIDEY_SOCKET_PATH:-}"
    printf 'TIDEY_WORKSPACE_ID=%s\n' "${TIDEY_WORKSPACE_ID:-}"
    printf 'TMUX_TMPDIR=%s\n' "${TMUX_TMPDIR:-}"
} > "${DEV_SANDBOX_TEST_LAUNCH_LOG:?}"
SH

make_fixture "$DEV_APP" com.tidey.app.dev "Tidey Dev"
make_fixture "$PROD_APP" com.tidey.app Tidey

env \
    HOME="$TMP_ROOT/home" \
    TMUX=/tmp/production-tmux,1,0 \
    TMUX_PANE=%42 \
    __CFBundleIdentifier=com.tidey.app \
    TIDEY_SOCKET_PATH=/tmp/production.sock \
    TIDEY_WORKSPACE_ID=production-workspace \
    DEV_SANDBOX_TEST_LAUNCH_LOG="$LOG_FILE" \
    bash "$RUNNER" "$DEV_APP"

grep -qx 'args=<-suite><tidey-dev-sandbox>' "$LOG_FILE" ||
    fail "Development launch did not use the isolated suite"
grep -qx 'TIDEY_DEV_SANDBOX=1' "$LOG_FILE" ||
    fail "Development launch did not mark the process as sandboxed"
for name in TMUX TMUX_PANE __CFBundleIdentifier TIDEY_SOCKET_PATH TIDEY_WORKSPACE_ID; do
    grep -qx "$name=" "$LOG_FILE" ||
        fail "Development launch retained $name"
done
expected_tmux_root="$TMP_ROOT/home/Library/Application Support/Tidey Dev Sandbox/tmux"
grep -qx "TMUX_TMPDIR=$expected_tmux_root" "$LOG_FILE" ||
    fail "Development launch did not isolate tmux state"
[[ -d "$expected_tmux_root" ]] ||
    fail "Development launch did not create its tmux root"

rm -f "$LOG_FILE"
if DEV_SANDBOX_TEST_LAUNCH_LOG="$LOG_FILE" bash "$RUNNER" "$PROD_APP" 2>/dev/null; then
    fail "Development runner accepted the production bundle"
fi
[[ ! -e "$LOG_FILE" ]] ||
    fail "Development runner launched the production executable"

grep -q 'Development/Tidey Dev.app' "$REPO/Makefile" ||
    fail "Development Makefile paths still reference Tidey.app"
grep -q 'tools/run-development-sandbox.sh' "$REPO/Makefile" ||
    fail "make run does not use the sandbox runner"

echo "PASS"
