#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/archive_production_app.sh --archive-name <name.bundle-archive>
       [--source-app /Applications/Tidey.app]
       [--backup-dir <existing-directory>]

Unregister an installed production Tidey bundle from LaunchServices, then move it
to a recoverable backup whose name cannot be discovered as an .app bundle.
EOF
}

SOURCE_APP="/Applications/Tidey.app"
BACKUP_DIR="${HOME:?}/Library/Application Support/Tidey/Deployment Backups"
ARCHIVE_NAME=""
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-app)
      SOURCE_APP="${2:-}"
      shift 2
      ;;
    --backup-dir)
      BACKUP_DIR="${2:-}"
      shift 2
      ;;
    --archive-name)
      ARCHIVE_NAME="${2:-}"
      shift 2
      ;;
    --lsregister)
      LSREGISTER="${2:-}"
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

if [[ -z "$ARCHIVE_NAME" ]]; then
  echo "Missing required --archive-name" >&2
  usage >&2
  exit 1
fi

if [[ "$SOURCE_APP" != /* || "$BACKUP_DIR" != /* || "$LSREGISTER" != /* ]]; then
  echo "Source app, backup directory, and lsregister paths must be absolute." >&2
  exit 1
fi

if [[ ! "$ARCHIVE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.bundle-archive$ ]]; then
  echo "Archive name must be a single safe leaf ending in .bundle-archive." >&2
  exit 1
fi

shopt -s nocasematch
if [[ "$ARCHIVE_NAME" == *".app"* ]]; then
  echo "Archive name must not contain .app." >&2
  exit 1
fi
shopt -u nocasematch

if [[ -L "$SOURCE_APP" ]]; then
  echo "Source app must not be a symbolic link: $SOURCE_APP" >&2
  exit 1
fi
if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Source app is missing or is not a directory: $SOURCE_APP" >&2
  exit 1
fi
if [[ -L "$BACKUP_DIR" ]]; then
  echo "Backup directory must not be a symbolic link: $BACKUP_DIR" >&2
  exit 1
fi
if [[ ! -d "$BACKUP_DIR" ]]; then
  echo "Backup directory is missing or is not a directory: $BACKUP_DIR" >&2
  exit 1
fi
if [[ -L "$LSREGISTER" || ! -f "$LSREGISTER" || ! -x "$LSREGISTER" ]]; then
  echo "lsregister must be an executable regular file: $LSREGISTER" >&2
  exit 1
fi

SOURCE_PHYSICAL="$(cd "$SOURCE_APP" && pwd -P)"
BACKUP_PHYSICAL="$(cd "$BACKUP_DIR" && pwd -P)"
case "$BACKUP_PHYSICAL/" in
  "$SOURCE_PHYSICAL/"*)
    echo "Backup directory must not be inside the source app." >&2
    exit 1
    ;;
esac

INFO_PLIST="$SOURCE_APP/Contents/Info.plist"
if [[ -L "$INFO_PLIST" || ! -f "$INFO_PLIST" ]]; then
  echo "Source app has no regular Info.plist: $INFO_PLIST" >&2
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
if [[ "$BUNDLE_ID" != "com.tidey.app" ]]; then
  echo "Unexpected bundle identifier: ${BUNDLE_ID:-<missing>}" >&2
  exit 1
fi

BUNDLE_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST" 2>/dev/null || true)"
EXECUTABLE_PATH="$SOURCE_APP/Contents/MacOS/$BUNDLE_EXECUTABLE"
if [[ -z "$BUNDLE_EXECUTABLE" || -L "$EXECUTABLE_PATH" || ! -f "$EXECUTABLE_PATH" ]]; then
  echo "Source app has no regular declared executable." >&2
  exit 1
fi

ARCHIVE_PATH="$BACKUP_PHYSICAL/$ARCHIVE_NAME"
if [[ -e "$ARCHIVE_PATH" || -L "$ARCHIVE_PATH" ]]; then
  echo "Archive path already exists: $ARCHIVE_PATH" >&2
  exit 1
fi

if ! "$LSREGISTER" -u "$SOURCE_APP"; then
  echo "LaunchServices unregister failed; source app was not moved." >&2
  exit 1
fi

if ! /bin/mv "$SOURCE_APP" "$ARCHIVE_PATH"; then
  "$LSREGISTER" -f "$SOURCE_APP" >/dev/null 2>&1 || true
  echo "Archiving failed; attempted to restore LaunchServices registration." >&2
  exit 1
fi

if [[ -e "$SOURCE_APP" || -L "$SOURCE_APP" || ! -d "$ARCHIVE_PATH" ]]; then
  echo "Archive postcondition failed: $ARCHIVE_PATH" >&2
  exit 1
fi

echo "Archived production Tidey bundle:"
echo "$ARCHIVE_PATH"
