#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SOURCE_SVG="$PROJECT_DIR/images/AppIcon/TideyAppIcon.svg"
STATUS_SOURCE_SVG="$PROJECT_DIR/images/AppIcon/TideyStatusItem.svg"
MASTER_PNG="$PROJECT_DIR/images/AppIcon.png"
ICONSET_DIR="$PROJECT_DIR/images/AppIcon.iconset"
ICNS_PATH="$PROJECT_DIR/images/AppIcon.icns"
NIGHTLY_ICON_PNG="$PROJECT_DIR/images/AppIcon/iTerm2 App Icon for Nightly.icon/Assets/TideyIcon.png"
DOC_ICON_PNG="$PROJECT_DIR/docs/screenshots/TideyAppIcon.png"

if [[ ! -f "$SOURCE_SVG" || ! -f "$STATUS_SOURCE_SVG" ]]; then
  echo "Missing Tidey icon SVG source." >&2
  exit 1
fi

mkdir -p "$ICONSET_DIR" "$(dirname "$NIGHTLY_ICON_PNG")"

/usr/bin/sips -s format png "$SOURCE_SVG" --out "$MASTER_PNG" >/dev/null
/usr/bin/sips -s format png "$SOURCE_SVG" --out "$NIGHTLY_ICON_PNG" >/dev/null
/usr/bin/sips -z 512 512 "$MASTER_PNG" --out "$DOC_ICON_PNG" >/dev/null

render_icon() {
  local size="$1"
  local output="$2"
  /usr/bin/sips -z "$size" "$size" "$MASTER_PNG" --out "$ICONSET_DIR/$output" >/dev/null
}

render_icon 16 icon_16x16.png
render_icon 32 icon_16x16@2x.png
render_icon 32 icon_32x32.png
render_icon 64 icon_32x32@2x.png
render_icon 128 icon_128x128.png
render_icon 256 icon_128x128@2x.png
render_icon 256 icon_256x256.png
render_icon 512 icon_256x256@2x.png
render_icon 512 icon_512x512.png
render_icon 1024 icon_512x512@2x.png

/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

/usr/bin/sips -s format png -z 16 22 "$STATUS_SOURCE_SVG" --out "$PROJECT_DIR/images/StatusItem.png" >/dev/null
/usr/bin/sips -s format png -z 32 44 "$STATUS_SOURCE_SVG" --out "$PROJECT_DIR/images/StatusItem@2x.png" >/dev/null

echo "Generated Tidey app, Nightly, status item, and documentation icon assets."
