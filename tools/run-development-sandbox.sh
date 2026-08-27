#!/usr/bin/env bash

set -euo pipefail

readonly EXPECTED_BUNDLE_ID="com.tidey.app.dev"
readonly EXPECTED_EXECUTABLE="Tidey Dev"
readonly DEVELOPMENT_SUITE="tidey-dev-sandbox"

fail() {
    echo "Tidey Dev sandbox: $*" >&2
    exit 1
}

[[ "$#" -eq 1 ]] || fail "usage: $0 /absolute/path/to/Tidey Dev.app"

app_path="$1"
[[ "$app_path" = /* ]] || fail "app path must be absolute"
[[ -d "$app_path" ]] || fail "app bundle does not exist: $app_path"

info_plist="$app_path/Contents/Info.plist"
[[ -f "$info_plist" ]] || fail "Info.plist is missing: $info_plist"

bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist" 2>/dev/null)" ||
    fail "CFBundleIdentifier is missing"
executable_name="$(plutil -extract CFBundleExecutable raw -o - "$info_plist" 2>/dev/null)" ||
    fail "CFBundleExecutable is missing"

[[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]] ||
    fail "refusing bundle identifier $bundle_id"
[[ "$executable_name" == "$EXPECTED_EXECUTABLE" ]] ||
    fail "refusing executable $executable_name"

executable_path="$app_path/Contents/MacOS/$executable_name"
[[ -x "$executable_path" ]] || fail "executable is missing: $executable_path"

unset TMUX
unset TMUX_PANE
unset __CFBundleIdentifier
while IFS='=' read -r env_name _; do
    case "$env_name" in
        TIDEY_*) unset "$env_name" ;;
    esac
done < <(env)

export TIDEY_DEV_SANDBOX=1
export TMUX_TMPDIR="$HOME/Library/Application Support/Tidey Dev Sandbox/tmux"
mkdir -p "$TMUX_TMPDIR"

exec "$executable_path" -suite "$DEVELOPMENT_SUITE"
