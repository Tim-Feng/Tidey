#!/bin/bash
set -euo pipefail

LABEL="${LABEL:-com.tidey.remote-bridge}"
SUPERVISOR_LABEL="${SUPERVISOR_LABEL:-$LABEL.cloudflared}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-4817}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIDGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SCRIPT="$BRIDGE_DIR/install.sh"
PLIST_PATH="${PLIST_PATH:-$HOME/Library/LaunchAgents/$LABEL.plist}"
SUPERVISOR_PLIST_PATH="${SUPERVISOR_PLIST_PATH:-$HOME/Library/LaunchAgents/$SUPERVISOR_LABEL.plist}"
HEALTH_URL="${HEALTH_URL:-http://$HOST:$PORT/admin/status}"
LAUNCHCTL_DOMAIN="gui/$(id -u)"
SERVICE_TARGET="$LAUNCHCTL_DOMAIN/$LABEL"
SUPERVISOR_TARGET="$LAUNCHCTL_DOMAIN/$SUPERVISOR_LABEL"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Builds the RemoteBridge release binary, installs it, signs it, restarts the launchd service,
and checks health via the admin endpoint.

Environment overrides:
  LABEL        launchd label (default: com.tidey.remote-bridge)
  HOST         admin endpoint host (default: 127.0.0.1)
  PORT         admin endpoint port (default: 4817)
  HEALTH_URL   full admin health URL (default: http://127.0.0.1:4817/admin/status)
  PLIST_PATH   launchd plist path (default: ~/Library/LaunchAgents/\$LABEL.plist)
  SUPERVISOR_LABEL supervisor launchd label (default: \$LABEL.cloudflared)
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 0 ]]; then
  usage >&2
  exit 1
fi

echo "Deploying Tidey Remote Bridge..."

BUILD_BRIDGE=1 LOAD_SERVICE=0 "$INSTALL_SCRIPT"

echo "Restarting launchd service..."
echo "Ensuring cloudflared supervisor..."
if launchctl print "$SUPERVISOR_TARGET" >/dev/null 2>&1; then
  launchctl kickstart "$SUPERVISOR_TARGET" >/dev/null 2>&1 || true
else
  launchctl bootstrap "$LAUNCHCTL_DOMAIN" "$SUPERVISOR_PLIST_PATH"
fi

if launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; then
  launchctl kickstart -k "$SERVICE_TARGET"
else
  launchctl bootstrap "$LAUNCHCTL_DOMAIN" "$PLIST_PATH"
fi

echo "Waiting for admin endpoint..."
for _ in {1..20}; do
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' "$HEALTH_URL" || true)"
  if [[ "$http_code" == "200" || "$http_code" == "401" ]]; then
    echo "Bridge healthy: $HEALTH_URL (http $http_code)"
    exit 0
  fi
  sleep 0.5
done

echo "Health check failed: $HEALTH_URL" >&2
if [[ -f "$PLIST_PATH" ]]; then
  echo "Plist: $PLIST_PATH" >&2
fi
exit 1
