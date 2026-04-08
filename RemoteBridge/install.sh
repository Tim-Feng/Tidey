#!/bin/bash
set -euo pipefail

LABEL="com.tidey.remote-bridge"
INSTALL_DIR="$HOME/Library/Application Support/Tidey Remote Bridge"
LOG_DIR="$HOME/Library/Logs/Tidey"
PLIST_DIR="$HOME/Library/LaunchAgents"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building release binary..."
cd "$SCRIPT_DIR"
swift build -c release 2>&1 | tail -1

echo "Installing binary..."
mkdir -p "$INSTALL_DIR"
cp -f .build/release/tidey-remote-bridge "$INSTALL_DIR/tidey-remote-bridge"
chmod 755 "$INSTALL_DIR/tidey-remote-bridge"

echo "Installing launchd plist..."
mkdir -p "$LOG_DIR"
mkdir -p "$PLIST_DIR"
sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/$LABEL.plist" > "$PLIST_DIR/$LABEL.plist"

echo "Loading service..."
launchctl unload "$PLIST_DIR/$LABEL.plist" 2>/dev/null || true
launchctl load "$PLIST_DIR/$LABEL.plist"

echo ""
echo "Tidey Remote Bridge installed and running."
echo "  Binary:  $INSTALL_DIR/tidey-remote-bridge"
echo "  Plist:   $PLIST_DIR/$LABEL.plist"
echo "  Log:     $LOG_DIR/remote-bridge.log"
