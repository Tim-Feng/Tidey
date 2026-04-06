#!/bin/bash
# Build, sign, notarize, and package Tidey for distribution.
# Usage: tools/release.sh
#
# Prerequisites:
#   - Developer ID Application certificate installed in Keychain
#   - Notarytool keychain profile "Tidey" configured:
#     xcrun notarytool store-credentials "Tidey" \
#       --apple-id "fsjforever26@gmail.com" --team-id "4T64VW5B7M"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SIGN_ID="Developer ID Application: Hsueh Cheng Feng (4T64VW5B7M)"
KEYCHAIN_PROFILE="Tidey"
DMG_PATH="$PROJECT_DIR/Tidey.dmg"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"

# Find DerivedData directory for this project
find_app() {
    local dd_dir
    dd_dir=$(find "$DERIVED_DATA" -maxdepth 1 -name "iTerm2-*" -type d | head -1)
    if [[ -z "$dd_dir" ]]; then
        echo "Error: No DerivedData directory found for iTerm2/Tidey" >&2
        exit 1
    fi
    echo "$dd_dir/Build/Products/Deployment/Tidey.app"
}

step() {
    echo ""
    echo "━━━ $1 ━━━"
}

# --- Preflight checks ---
step "Preflight"

if ! security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    echo "Error: Signing certificate not found: $SIGN_ID" >&2
    exit 1
fi
echo "Certificate: OK"

if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    echo "Error: Keychain profile '$KEYCHAIN_PROFILE' not configured." >&2
    echo "Run: xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" --apple-id ... --team-id 4T64VW5B7M" >&2
    exit 1
fi
echo "Keychain profile: OK"

# --- Build ---
step "Build Deployment"

cd "$PROJECT_DIR"
xcodebuild clean -project iTerm2.xcodeproj -scheme iTerm2 -configuration Deployment -quiet 2>&1 | tail -1
tools/build.sh Deployment

APP_PATH="$(find_app)"
if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: Built app not found at $APP_PATH" >&2
    exit 1
fi
echo "App: $APP_PATH"

# --- Sign ---
step "Code Sign"

# Sign inner Mach-O binaries that --deep might miss
find "$APP_PATH" -type f -perm +111 | while read -r f; do
    if file -b "$f" | grep -q "Mach-O"; then
        codesign -dv "$f" 2>&1 | grep -q "Developer ID" || {
            echo "  Signing: ${f#$APP_PATH/}"
            codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$f"
        }
    fi
done

# Sign the outer app bundle
echo "  Signing: Tidey.app"
codesign --deep --force --options runtime --timestamp --sign "$SIGN_ID" "$APP_PATH"

# Verify
codesign --verify --deep --strict "$APP_PATH"
echo "Signature: verified"

# --- Package DMG ---
step "Create DMG"

hdiutil create -volname "Tidey" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH" 2>&1
codesign --force --sign "$SIGN_ID" "$DMG_PATH"
echo "DMG: $DMG_PATH"

# --- Notarize ---
step "Notarize"

xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait

# --- Staple ---
step "Staple"

xcrun stapler staple "$DMG_PATH"

# --- Verify ---
step "Final Check"

spctl --assess -t open --context context:primary-signature -v "$DMG_PATH" 2>&1
echo ""
echo "Done. DMG ready at: $DMG_PATH"
echo "Upload: gh release upload v0.1.0 \"$DMG_PATH\" --clobber"
