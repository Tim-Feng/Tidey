#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: tools/bundle_remote_bridge.sh <app-resources-remote-bridge-dir>" >&2
    exit 64
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$PROJECT_DIR/RemoteBridge"
RESOURCES_DIR="$1"
SCRATCH_PATH="${TIDEY_REMOTE_BRIDGE_SCRATCH_PATH:-$BRIDGE_DIR/.build}"
CACHE_PATH="${TIDEY_REMOTE_BRIDGE_CACHE_PATH:-}"
BRIDGE_BINARY="$SCRATCH_PATH/release/tidey-remote-bridge"

swift_build_args=(-c release --package-path "$BRIDGE_DIR" --scratch-path "$SCRATCH_PATH")
if [[ -n "$CACHE_PATH" ]]; then
    swift_build_args+=(--cache-path "$CACHE_PATH")
fi

swift build "${swift_build_args[@]}" 2>&1 | tail -1
if [[ ! -x "$BRIDGE_BINARY" ]]; then
    echo "Error: RemoteBridge binary not found at $BRIDGE_BINARY" >&2
    exit 1
fi

mkdir -p "$RESOURCES_DIR"
cp -f "$BRIDGE_BINARY" "$RESOURCES_DIR/tidey-remote-bridge"
chmod 755 "$RESOURCES_DIR/tidey-remote-bridge"
cp -f "$BRIDGE_DIR/com.tidey.remote-bridge.plist" "$RESOURCES_DIR/com.tidey.remote-bridge.plist.template"
cp -f "$BRIDGE_DIR/com.tidey.remote-bridge.cloudflared.plist" "$RESOURCES_DIR/com.tidey.remote-bridge.cloudflared.plist.template"

echo "RemoteBridge: $RESOURCES_DIR/tidey-remote-bridge"
echo "LaunchAgents: bundled plist templates"
