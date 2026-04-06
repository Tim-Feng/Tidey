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
STAGING=""

cleanup() {
    [[ -n "${STAGING:-}" ]] && hdiutil detach "$STAGING/mnt" 2>/dev/null || true
    [[ -n "${STAGING:-}" && -d "${STAGING:-}" ]] && rm -rf "$STAGING"
}

trap cleanup EXIT

# Resolve the exact build products directory for this build.
find_app() {
    local built_products_dir
    built_products_dir=$(
        xcodebuild -project iTerm2.xcodeproj -scheme iTerm2 -configuration Deployment -showBuildSettings 2>/dev/null |
            grep ' BUILT_PRODUCTS_DIR' |
            awk -F ' = ' 'NR == 1 { print $2 }' || true
    )
    if [[ -z "$built_products_dir" ]]; then
        echo "Error: Unable to determine BUILT_PRODUCTS_DIR for iTerm2/Tidey" >&2
        exit 1
    fi
    echo "$built_products_dir/Tidey.app"
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
find "$APP_PATH" \( -name "*.app" -o -name "*.framework" -o -name "*.xpc" -o -name "*.bundle" -o -name "*.appex" -o -name "*.pluginkit" -o -name "*.plugin" -o -name "*.prefPane" -o -name "*.qlgenerator" \) -type d -not -path "$APP_PATH" -depth | while read -r bundle; do
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
APP_SIZE_KB=$(du -sk "$STAGING/Tidey.app" | cut -f1)
DMG_SIZE_MB=$(( (APP_SIZE_KB / 1024) + 50 ))
hdiutil create -size "${DMG_SIZE_MB}m" -fs HFS+ -volname "Tidey" "$TEMP_DMG" 2>&1
hdiutil attach "$TEMP_DMG" -nobrowse -mountpoint "$STAGING/mnt" 2>&1
cp -R "$STAGING/Tidey.app" "$STAGING/mnt/"
ln -s /Applications "$STAGING/mnt/Applications"
hdiutil detach "$STAGING/mnt" 2>&1
hdiutil convert "$TEMP_DMG" -format UDZO -o "$DMG_PATH" -ov 2>&1
codesign --force --timestamp --sign "$SIGN_ID" "$DMG_PATH"
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

# Update the appcast XML with the current release item.
python3 -c "
import xml.etree.ElementTree as ET

ET.register_namespace('sparkle', 'http://www.andymatuschak.net/xml-namespaces/sparkle')
ET.register_namespace('dc', 'http://purl.org/dc/elements/1.1/')
tree = ET.parse('$APPCAST')
channel = tree.find('channel')
ns = {'sparkle': 'http://www.andymatuschak.net/xml-namespaces/sparkle'}
if channel is None:
    raise SystemExit('Error: channel element not found in appcast')
for item in channel.findall('item'):
    ver = item.find('sparkle:shortVersionString', ns)
    if ver is not None and ver.text == '$VERSION':
        channel.remove(item)
item = ET.SubElement(channel, 'item')
ET.SubElement(item, 'title').text = 'Tidey $VERSION'
ET.SubElement(item, 'pubDate').text = '$PUB_DATE'
ET.SubElement(item, '{http://www.andymatuschak.net/xml-namespaces/sparkle}version').text = '$BUILD'
ET.SubElement(item, '{http://www.andymatuschak.net/xml-namespaces/sparkle}shortVersionString').text = '$VERSION'
ET.SubElement(item, '{http://www.andymatuschak.net/xml-namespaces/sparkle}minimumSystemVersion').text = '12.0'
enc = ET.SubElement(item, 'enclosure')
enc.set('url', '$DMG_URL')
enc.set('type', 'application/octet-stream')
enc.set('{http://www.andymatuschak.net/xml-namespaces/sparkle}edSignature', '$SPARKLE_SIG')
enc.set('length', '$DMG_SIZE')
tree.write('$APPCAST', xml_declaration=True, encoding='utf-8')
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
