#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/sync_wrappers.sh --source-app /path/to/Tidey.app [--target-app /Applications/Tidey.app]

Sync the installed Tidey app's runtime bin payload from a freshly built app bundle.
This copies:
  - tidey
  - claude
  - codex

The sync includes the Tidey CLI binary because Claude session-start fixes live there,
not only in the wrapper scripts.
EOF
}

SOURCE_APP=""
TARGET_APP="/Applications/Tidey.app"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-app)
      SOURCE_APP="${2:-}"
      shift 2
      ;;
    --target-app)
      TARGET_APP="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SOURCE_APP" ]]; then
  echo "Missing required --source-app" >&2
  usage >&2
  exit 1
fi

SOURCE_BIN_DIR="$SOURCE_APP/Contents/Resources/bin"
TARGET_BIN_DIR="$TARGET_APP/Contents/Resources/bin"

for path in "$SOURCE_APP" "$TARGET_APP" "$SOURCE_BIN_DIR" "$TARGET_BIN_DIR"; do
  if [[ ! -e "$path" ]]; then
    echo "Missing required path: $path" >&2
    exit 1
  fi
done

for name in tidey claude codex; do
  source_file="$SOURCE_BIN_DIR/$name"
  target_file="$TARGET_BIN_DIR/$name"
  if [[ ! -f "$source_file" ]]; then
    echo "Missing source binary: $source_file" >&2
    exit 1
  fi
  install -m 755 "$source_file" "$target_file"
done

echo "Synced Tidey runtime bin payload:"
echo "  source: $SOURCE_APP"
echo "  target: $TARGET_APP"
