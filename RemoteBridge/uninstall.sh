#!/bin/bash
set -euo pipefail

LABEL="com.tidey.remote-bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "Stopping service..."
launchctl unload "$PLIST" 2>/dev/null || true

echo "Removing plist..."
rm -f "$PLIST"

echo "Removing binary..."
rm -f "$HOME/Library/Application Support/Tidey Remote Bridge/tidey-remote-bridge"

echo "Tidey Remote Bridge uninstalled."
echo "(Token and logs preserved)"
