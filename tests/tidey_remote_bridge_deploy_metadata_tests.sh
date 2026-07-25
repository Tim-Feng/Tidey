#!/usr/bin/env bash
set -euo pipefail

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

REPO="$ROOT/tidey"
SCRIPT_UNDER_TEST="$REPO/RemoteBridge/tools/deploy-bridge.sh"
INSTALL_DIR="$ROOT/install"
DEPLOY_METADATA_PATH="$INSTALL_DIR/deploy-metadata.json"
BIN_DIR="$ROOT/bin"
LAUNCHCTL_LOG="$ROOT/launchctl.log"
LAUNCHCTL_STATE_DIR="$ROOT/launchctl-state"

mkdir -p "$REPO/RemoteBridge/tools" "$BIN_DIR" "$LAUNCHCTL_STATE_DIR"
touch "$LAUNCHCTL_STATE_DIR/service-loaded"
cp "$(cd "$(dirname "$0")/.." && pwd)/RemoteBridge/tools/deploy-bridge.sh" "$SCRIPT_UNDER_TEST"

cat > "$REPO/RemoteBridge/install.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$INSTALL_DIR"
printf 'bridge-binary' > "$INSTALL_DIR/tidey-remote-bridge"
SH
chmod +x "$REPO/RemoteBridge/install.sh"

cat > "$BIN_DIR/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
if [[ "${1:-}" == "print" ]]; then
  if [[ "${2:-}" == *".cloudflared" ]]; then
    exit 0
  fi
  if [[ -f "$LAUNCHCTL_STATE_DIR/unload-polls" ]]; then
    polls="$(<"$LAUNCHCTL_STATE_DIR/unload-polls")"
    polls=$((polls - 1))
    if [[ "$polls" -le 0 ]]; then
      rm -f "$LAUNCHCTL_STATE_DIR/unload-polls" "$LAUNCHCTL_STATE_DIR/service-loaded"
      exit 1
    fi
    printf '%s\n' "$polls" > "$LAUNCHCTL_STATE_DIR/unload-polls"
  fi
  test -f "$LAUNCHCTL_STATE_DIR/service-loaded"
  exit
fi
if [[ "${1:-}" == "bootout" ]]; then
  printf '2\n' > "$LAUNCHCTL_STATE_DIR/unload-polls"
  exit 0
fi
if [[ "${1:-}" == "bootstrap" ]]; then
  count=0
  if [[ -f "$LAUNCHCTL_STATE_DIR/bootstrap-count" ]]; then
    count="$(<"$LAUNCHCTL_STATE_DIR/bootstrap-count")"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$LAUNCHCTL_STATE_DIR/bootstrap-count"
  if [[ -f "$LAUNCHCTL_STATE_DIR/service-loaded" ]]; then
    printf 'Bootstrap failed: 5: Input/output error\n' >&2
    exit 5
  fi
  if [[ ! -f "$LAUNCHCTL_STATE_DIR/post-unload-bootstrap-failure-used" ]]; then
    touch "$LAUNCHCTL_STATE_DIR/post-unload-bootstrap-failure-used"
    printf 'Bootstrap failed: 5: Input/output error\n' >&2
    exit 5
  fi
  rm -f "$LAUNCHCTL_STATE_DIR/unload-polls"
  touch "$LAUNCHCTL_STATE_DIR/service-loaded"
  exit 0
fi
exit 0
SH
chmod +x "$BIN_DIR/launchctl"

cat > "$BIN_DIR/curl" <<'SH'
#!/usr/bin/env bash
printf '200'
SH
chmod +x "$BIN_DIR/curl"

cat > "$BIN_DIR/git" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"rev-parse --short=9 HEAD"* ]]; then
  printf 'abc123456\n'
  exit 0
fi
exit 1
SH
chmod +x "$BIN_DIR/git"

PATH="$BIN_DIR:$PATH" \
LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
LAUNCHCTL_STATE_DIR="$LAUNCHCTL_STATE_DIR" \
LAUNCHCTL_RETRY_INTERVAL_SECONDS=0 \
INSTALL_DIR="$INSTALL_DIR" \
PLIST_PATH="$ROOT/bridge.plist" \
SUPERVISOR_PLIST_PATH="$ROOT/cloudflared.plist" \
DEPLOY_METADATA_PATH="$DEPLOY_METADATA_PATH" \
HOME="$ROOT/home" \
bash "$SCRIPT_UNDER_TEST" >/tmp/tidey-bridge-deploy-test.out

GUI_DOMAIN="gui/$(id -u)"
grep -Fqx "bootout $GUI_DOMAIN $ROOT/bridge.plist" "$LAUNCHCTL_LOG"
test "$(<"$LAUNCHCTL_STATE_DIR/bootstrap-count")" -eq 2
test "$(grep -Fxc "bootstrap $GUI_DOMAIN $ROOT/bridge.plist" "$LAUNCHCTL_LOG")" -eq 2
if grep -Fq "kickstart -k $GUI_DOMAIN/com.tidey.remote-bridge" "$LAUNCHCTL_LOG"; then
  echo "main Bridge deployment must re-bootstrap launchd after replacing the signed binary" >&2
  exit 1
fi

test -f "$DEPLOY_METADATA_PATH"
python3 - "$DEPLOY_METADATA_PATH" "$INSTALL_DIR/tidey-remote-bridge" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

metadata_path = Path(sys.argv[1])
binary_path = Path(sys.argv[2])
payload = json.loads(metadata_path.read_text(encoding="utf-8"))
expected_sha = hashlib.sha256(binary_path.read_bytes()).hexdigest()

assert payload["schema"] == "tidey.remote_bridge.deploy"
assert payload["tidey_git_head"] == "abc123456"
assert payload["bridge_binary_path"] == str(binary_path)
assert payload["bridge_binary_sha256"] == expected_sha
assert payload["bridge_binary_size"] == binary_path.stat().st_size
assert "deployed_at" in payload
PY

METADATA_FAILURE_INSTALL_DIR="$ROOT/install-metadata-failure"
mkdir -p "$METADATA_FAILURE_INSTALL_DIR"
set +e
PATH="$BIN_DIR:$PATH" \
LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
LAUNCHCTL_STATE_DIR="$LAUNCHCTL_STATE_DIR" \
LAUNCHCTL_RETRY_INTERVAL_SECONDS=0 \
INSTALL_DIR="$METADATA_FAILURE_INSTALL_DIR" \
PLIST_PATH="$ROOT/bridge-metadata-failure.plist" \
SUPERVISOR_PLIST_PATH="$ROOT/cloudflared-metadata-failure.plist" \
DEPLOY_METADATA_PATH="$METADATA_FAILURE_INSTALL_DIR" \
HOME="$ROOT/home" \
bash "$SCRIPT_UNDER_TEST" >"$ROOT/metadata-failure.out" 2>"$ROOT/metadata-failure.err"
STATUS=$?
set -e

test "$STATUS" -eq 0
grep -q "warning: failed to write deploy metadata" "$ROOT/metadata-failure.err"
