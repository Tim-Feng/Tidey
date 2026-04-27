#!/bin/bash
set -euo pipefail

LABEL="${LABEL:-com.tidey.remote-bridge}"
SUPERVISOR_LABEL="${SUPERVISOR_LABEL:-$LABEL.cloudflared}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Library/Application Support/Tidey Remote Bridge}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/Tidey}"
PLIST_DIR="${PLIST_DIR:-$HOME/Library/LaunchAgents}"
BUILD_BRIDGE="${BUILD_BRIDGE:-1}"
LOAD_SERVICE="${LOAD_SERVICE:-1}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_BINARY="${SOURCE_BINARY:-$SCRIPT_DIR/.build/release/tidey-remote-bridge}"
TARGET_BINARY="$INSTALL_DIR/tidey-remote-bridge"

if [[ "$BUILD_BRIDGE" == "1" ]]; then
  echo "Building release binary..."
  cd "$SCRIPT_DIR"
  swift build -c release 2>&1 | tail -1
fi

echo "Installing binary..."
mkdir -p "$INSTALL_DIR"
cp -f "$SOURCE_BINARY" "$TARGET_BINARY"
chmod 755 "$TARGET_BINARY"

echo "Signing binary..."
codesign --force --sign - "$TARGET_BINARY" >/dev/null 2>&1

echo "Installing launchd plist..."
mkdir -p "$LOG_DIR"
mkdir -p "$PLIST_DIR"
sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/$LABEL.plist" > "$PLIST_DIR/$LABEL.plist"
sed -e "s|__HOME__|$HOME|g" \
    -e "s|__LABEL__|$SUPERVISOR_LABEL|g" \
    "$SCRIPT_DIR/com.tidey.remote-bridge.cloudflared.plist" > "$PLIST_DIR/$SUPERVISOR_LABEL.plist"

if [[ "$LOAD_SERVICE" == "1" ]]; then
  echo "Loading service..."
  launchctl unload "$PLIST_DIR/$LABEL.plist" 2>/dev/null || true
  launchctl load "$PLIST_DIR/$LABEL.plist"
  launchctl unload "$PLIST_DIR/$SUPERVISOR_LABEL.plist" 2>/dev/null || true
  launchctl load "$PLIST_DIR/$SUPERVISOR_LABEL.plist"
fi

echo ""
echo "Tidey Remote Bridge installed and running."
echo "  Binary:  $TARGET_BINARY"
echo "  Plist:   $PLIST_DIR/$LABEL.plist"
echo "  Tunnel:  $PLIST_DIR/$SUPERVISOR_LABEL.plist"
echo "  Log:     $LOG_DIR/remote-bridge.log"
echo "  Signed:  ad-hoc via codesign --sign -"
