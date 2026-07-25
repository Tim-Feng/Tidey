#!/bin/bash
set -euo pipefail

LABEL="${LABEL:-com.tidey.remote-bridge}"
SUPERVISOR_LABEL="${SUPERVISOR_LABEL:-$LABEL.cloudflared}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-4817}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIDGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TIDEY_REPO_DIR="$(cd "$BRIDGE_DIR/.." && pwd)"
INSTALL_SCRIPT="$BRIDGE_DIR/install.sh"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Library/Application Support/Tidey Remote Bridge}"
TARGET_BINARY="${TARGET_BINARY:-$INSTALL_DIR/tidey-remote-bridge}"
DEPLOY_METADATA_PATH="${DEPLOY_METADATA_PATH:-$INSTALL_DIR/deploy-metadata.json}"
PLIST_PATH="${PLIST_PATH:-$HOME/Library/LaunchAgents/$LABEL.plist}"
SUPERVISOR_PLIST_PATH="${SUPERVISOR_PLIST_PATH:-$HOME/Library/LaunchAgents/$SUPERVISOR_LABEL.plist}"
HEALTH_URL="${HEALTH_URL:-http://$HOST:$PORT/admin/status}"
HEALTH_CHECK_ATTEMPTS="${HEALTH_CHECK_ATTEMPTS:-120}"
HEALTH_CHECK_INTERVAL_SECONDS="${HEALTH_CHECK_INTERVAL_SECONDS:-0.5}"
LAUNCHCTL_UNLOAD_CHECK_ATTEMPTS="${LAUNCHCTL_UNLOAD_CHECK_ATTEMPTS:-50}"
LAUNCHCTL_BOOTSTRAP_ATTEMPTS="${LAUNCHCTL_BOOTSTRAP_ATTEMPTS:-5}"
LAUNCHCTL_RETRY_INTERVAL_SECONDS="${LAUNCHCTL_RETRY_INTERVAL_SECONDS:-0.1}"
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
  HEALTH_CHECK_ATTEMPTS health check attempts after restart (default: 120)
  HEALTH_CHECK_INTERVAL_SECONDS seconds between health attempts (default: 0.5)
  LAUNCHCTL_UNLOAD_CHECK_ATTEMPTS checks before treating a loaded service as stale (default: 50)
  LAUNCHCTL_BOOTSTRAP_ATTEMPTS retries for launchctl bootstrap exit 5 / I/O races (default: 5)
  LAUNCHCTL_RETRY_INTERVAL_SECONDS seconds between launchctl checks and retries (default: 0.1)
  PLIST_PATH   launchd plist path (default: ~/Library/LaunchAgents/\$LABEL.plist)
  SUPERVISOR_LABEL supervisor launchd label (default: \$LABEL.cloudflared)
  DEPLOY_METADATA_PATH deploy metadata JSON path (default: ~/Library/Application Support/Tidey Remote Bridge/deploy-metadata.json)
EOF
}

write_deploy_metadata() {
  local repo_head
  repo_head="$(git -C "$TIDEY_REPO_DIR" rev-parse --short=9 HEAD 2>/dev/null || true)"
  if python3 - "$DEPLOY_METADATA_PATH" "$TIDEY_REPO_DIR" "$repo_head" "$TARGET_BINARY" <<'PY'
import datetime as dt
import hashlib
import json
import os
import sys
import tempfile

metadata_path, repo_dir, repo_head, binary_path = sys.argv[1:5]

digest = hashlib.sha256()
with open(binary_path, "rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)

stat = os.stat(binary_path)
payload = {
    "schema": "tidey.remote_bridge.deploy",
    "deployed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    "tidey_repo_path": repo_dir,
    "tidey_git_head": repo_head or None,
    "bridge_binary_path": binary_path,
    "bridge_binary_sha256": digest.hexdigest(),
    "bridge_binary_size": stat.st_size,
    "bridge_binary_mtime": dt.datetime.fromtimestamp(stat.st_mtime, dt.timezone.utc).isoformat(),
}

os.makedirs(os.path.dirname(metadata_path), exist_ok=True)
with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=os.path.dirname(metadata_path), delete=False) as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
    temp_name = handle.name
os.replace(temp_name, metadata_path)
PY
  then
    echo "Deploy metadata: $DEPLOY_METADATA_PATH"
  else
    return 1
  fi
}

wait_for_launch_agent_to_unload() {
  local attempt
  for ((attempt = 1; attempt <= LAUNCHCTL_UNLOAD_CHECK_ATTEMPTS; attempt++)); do
    if ! launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; then
      return 0
    fi
    if [[ "$attempt" -lt "$LAUNCHCTL_UNLOAD_CHECK_ATTEMPTS" ]]; then
      sleep "$LAUNCHCTL_RETRY_INTERVAL_SECONDS"
    fi
  done
  return 1
}

bootstrap_bridge_service() {
  local attempt
  local bootstrap_output=""
  local bootstrap_status=1
  for ((attempt = 1; attempt <= LAUNCHCTL_BOOTSTRAP_ATTEMPTS; attempt++)); do
    if bootstrap_output="$(launchctl bootstrap "$LAUNCHCTL_DOMAIN" "$PLIST_PATH" 2>&1)"; then
      return 0
    else
      bootstrap_status=$?
    fi

    if [[ "$bootstrap_status" -ne 5 && "$bootstrap_output" != *"Input/output error"* ]]; then
      printf '%s\n' "$bootstrap_output" >&2
      return "$bootstrap_status"
    fi
    if [[ "$attempt" -lt "$LAUNCHCTL_BOOTSTRAP_ATTEMPTS" ]]; then
      wait_for_launch_agent_to_unload || true
      sleep "$LAUNCHCTL_RETRY_INTERVAL_SECONDS"
    fi
  done

  printf '%s\n' "$bootstrap_output" >&2
  return "$bootstrap_status"
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
  launchctl bootout "$LAUNCHCTL_DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || true
  wait_for_launch_agent_to_unload || true
fi
bootstrap_bridge_service

echo "Waiting for admin endpoint..."
for ((attempt = 1; attempt <= HEALTH_CHECK_ATTEMPTS; attempt++)); do
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' "$HEALTH_URL" || true)"
  if [[ "$http_code" == "200" || "$http_code" == "401" ]]; then
    echo "Bridge healthy: $HEALTH_URL (http $http_code)"
    write_deploy_metadata || echo "warning: failed to write deploy metadata" >&2
    exit 0
  fi
  if [[ "$attempt" -lt "$HEALTH_CHECK_ATTEMPTS" ]]; then
    sleep "$HEALTH_CHECK_INTERVAL_SECONDS"
  fi
done

echo "Health check failed: $HEALTH_URL" >&2
if [[ -f "$PLIST_PATH" ]]; then
  echo "Plist: $PLIST_PATH" >&2
fi
exit 1
