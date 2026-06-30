#!/usr/bin/env bash
set -euo pipefail

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

REPO="$ROOT/tidey"
SCRIPT_UNDER_TEST="$REPO/RemoteBridge/tools/deploy-bridge.sh"
INSTALL_DIR="$ROOT/install"
DEPLOY_METADATA_PATH="$INSTALL_DIR/deploy-metadata.json"
BIN_DIR="$ROOT/bin"

mkdir -p "$REPO/RemoteBridge/tools" "$BIN_DIR"
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
if [[ "${1:-}" == "print" ]]; then
  exit 1
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
INSTALL_DIR="$INSTALL_DIR" \
PLIST_PATH="$ROOT/bridge.plist" \
SUPERVISOR_PLIST_PATH="$ROOT/cloudflared.plist" \
DEPLOY_METADATA_PATH="$DEPLOY_METADATA_PATH" \
HOME="$ROOT/home" \
bash "$SCRIPT_UNDER_TEST" >/tmp/tidey-bridge-deploy-test.out

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
