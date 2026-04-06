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

# Sign everything inside-out: find all signable items, sort deepest-first
# Covers: .dylib, .xpc, .app, .framework, .bundle, standalone Mach-O

# 1. Sign all loose Mach-O files EXCEPT the main executable
#    (main executable gets signed as part of the outer app bundle in step 3)
MAIN_EXE="$APP_PATH/Contents/MacOS/Tidey"
find "$APP_PATH" -type f | while read -r f; do
    [[ "$f" == "$MAIN_EXE" ]] && continue
    if file -b "$f" | grep -q "Mach-O"; then
        codesign -dv "$f" 2>&1 | grep -q "Developer ID" || {
            echo "  Signing: ${f#$APP_PATH/}"
            codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$f"
        }
    fi
done

# 2. Sign all code bundles (deepest first via -depth)
find "$APP_PATH" \( -name "*.app" -o -name "*.framework" -o -name "*.xpc" -o -name "*.bundle" \) -type d -not -path "$APP_PATH" -depth | while read -r bundle; do
    echo "  Signing: ${bundle#$APP_PATH/}"
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$bundle"
done

# 3. Sign the outer app bundle
echo "  Signing: Tidey.app"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP_PATH"

# Verify
codesign --verify --deep --strict "$APP_PATH"
echo "Signature: verified"

# --- Package DMG ---
step "Create DMG"

# Stage in temp dir and create writable image manually to avoid /Volumes name collisions
STAGING=$(mktemp -d)
cp -R "$APP_PATH" "$STAGING/"
hdiutil detach /Volumes/Tidey 2>/dev/null || true
TEMP_DMG="$STAGING/tidey-temp.dmg"
hdiutil create -size 200m -fs HFS+ -volname "Tidey" "$TEMP_DMG" 2>&1
hdiutil attach "$TEMP_DMG" -nobrowse -mountpoint "$STAGING/mnt" 2>&1
cp -R "$STAGING/Tidey.app" "$STAGING/mnt/"
ln -s /Applications "$STAGING/mnt/Applications"
hdiutil detach "$STAGING/mnt" 2>&1
hdiutil convert "$TEMP_DMG" -format UDZO -o "$DMG_PATH" -ov 2>&1
rm -rf "$STAGING"
codesign --force --sign "$SIGN_ID" "$DMG_PATH"
echo "DMG: $DMG_PATH"

# --- Notarize ---
step "Notarize"

xcrun notarytool submit "$DMG_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait

# --- Staple ---
step "Staple"

xcrun stapler staple "$DMG_PATH"

# --- Sparkle Signing ---
step "Sparkle Sign"

SPARKLE_OUTPUT=$(python3 "$SCRIPT_DIR/sign_sparkle_update.py" "$DMG_PATH")
SPARKLE_SIG=$(echo "$SPARKLE_OUTPUT" | tail -1)
DMG_SIZE=$(stat -f%z "$DMG_PATH")
echo "EdDSA signature: $SPARKLE_SIG"
echo "DMG size: $DMG_SIZE bytes"

# --- Update Appcast ---
step "Update Appcast"

VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")
APPCAST="$PROJECT_DIR/docs/appcast.xml"
PUB_DATE=$(date -R)
DMG_URL="https://github.com/Tim-Feng/Tidey/releases/download/v${VERSION}/Tidey.dmg"

# Create the new item XML
NEW_ITEM="    <item>
      <title>Tidey $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      <enclosure url=\"$DMG_URL\"
                 type=\"application/octet-stream\"
                 sparkle:edSignature=\"$SPARKLE_SIG\"
                 length=\"$DMG_SIZE\" />
    </item>"

# Insert before </channel> — remove any existing item with same version first
python3 -c "
import re, sys
appcast = open('$APPCAST').read()
# Remove existing items with same version
appcast = re.sub(r'    <item>\n.*?<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>.*?</item>\n', '', appcast, flags=re.DOTALL)
# Insert new item before </channel>
appcast = appcast.replace('  </channel>', '''$NEW_ITEM
  </channel>''')
open('$APPCAST', 'w').write(appcast)
"

echo "Appcast updated: $APPCAST"
echo "Version: $VERSION (build $BUILD)"

# --- Verify ---
step "Final Check"

spctl --assess -t open --context context:primary-signature -v "$DMG_PATH" 2>&1
echo ""
echo "Done. DMG ready at: $DMG_PATH"
echo ""
echo "Next steps:"
echo "  1. gh release upload v$VERSION \"$DMG_PATH\" --clobber"
echo "  2. git add docs/appcast.xml && git commit -m 'Update appcast for v$VERSION'"
echo "  3. git push origin master  # deploys appcast via GitHub Pages"
