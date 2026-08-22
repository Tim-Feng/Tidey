#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPATCH_UNDER_TEST="$SCRIPT_DIR/../Resources/bin/codex-hook-dispatch"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

wait_for_file() {
    local path="$1"
    local iteration

    for iteration in $(seq 1 100); do
        [[ -f "$path" ]] && return 0
        sleep 0.01
    done
    return 1
}

run_stop_plays_user_job_done_sound_test() {
    local tmpdir
    local bin_dir
    local fake_home
    local sound_file
    local player_log
    local tidey_log

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/tidey-codex-hook-dispatch-tests.XXXXXX")"
    tmpdir="$(cd "$tmpdir" && pwd -P)"
    trap 'rm -rf "$tmpdir"' RETURN
    bin_dir="$tmpdir/Resources/bin"
    fake_home="$tmpdir/home"
    sound_file="$fake_home/.claude/sounds/jobs-done.mp3"
    player_log="$tmpdir/player.log"
    tidey_log="$tmpdir/tidey.log"
    mkdir -p "$bin_dir" "$(dirname "$sound_file")"
    : > "$sound_file"
    ln -s "$DISPATCH_UNDER_TEST" "$bin_dir/codex-hook-dispatch"

    cat > "$bin_dir/tidey-tmux-pane-identity" <<'FAKE_IDENTITY'
tidey_hydrate_tmux_pane_identity() { :; }
FAKE_IDENTITY

    cat > "$bin_dir/tidey" <<'FAKE_TIDEY'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${FAKE_TIDEY_LOG:?}"
FAKE_TIDEY

    cat > "$tmpdir/fake-afplay" <<'FAKE_AFPLAY'
#!/usr/bin/env bash
printf '%s\n' "$1" > "${FAKE_PLAYER_LOG:?}"
FAKE_AFPLAY
    chmod +x "$bin_dir/tidey" "$tmpdir/fake-afplay"

    HOME="$fake_home" \
        TMPDIR="$tmpdir" \
        TIDEY_CODEX_HOOKS_ENABLED=1 \
        TIDEY_WORKSPACE_ID=workspace-1 \
        TIDEY_PANEL_ID=panel-1 \
        TIDEY_COMPLETION_SOUND_PLAYER="$tmpdir/fake-afplay" \
        FAKE_PLAYER_LOG="$player_log" \
        FAKE_TIDEY_LOG="$tidey_log" \
        "$bin_dir/codex-hook-dispatch" stop '{"last-assistant-message":"Done"}'

    wait_for_file "$player_log" || fail "Codex Stop did not start the completion sound player"
    [[ "$(cat "$player_log")" == "$sound_file" ]] || fail "Codex Stop did not prefer the user's Warcraft completion sound"
    [[ "$(cat "$tidey_log")" == 'codex-hook stop {"last-assistant-message":"Done"}' ]] || fail "Codex Stop did not preserve Tidey hook dispatch"

    rm -f "$player_log"
    HOME="$fake_home" \
        TMPDIR="$tmpdir" \
        TIDEY_CODEX_HOOKS_ENABLED=1 \
        TIDEY_WORKSPACE_ID=workspace-1 \
        TIDEY_PANEL_ID=panel-1 \
        TIDEY_COMPLETION_SOUND_PLAYER="$tmpdir/fake-afplay" \
        FAKE_PLAYER_LOG="$player_log" \
        FAKE_TIDEY_LOG="$tidey_log" \
        "$bin_dir/codex-hook-dispatch" user-prompt-submit
    sleep 0.05
    [[ ! -f "$player_log" ]] || fail "a non-Stop Codex hook played the completion sound"

    rm -f "$sound_file"
    : > "$tmpdir/Resources/success-sound.mp3"
    HOME="$fake_home" \
        TMPDIR="$tmpdir" \
        TIDEY_CODEX_HOOKS_ENABLED=1 \
        TIDEY_WORKSPACE_ID=workspace-1 \
        TIDEY_PANEL_ID=panel-1 \
        TIDEY_COMPLETION_SOUND_PLAYER="$tmpdir/fake-afplay" \
        FAKE_PLAYER_LOG="$player_log" \
        FAKE_TIDEY_LOG="$tidey_log" \
        "$bin_dir/codex-hook-dispatch" stop
    wait_for_file "$player_log" || fail "Codex Stop did not use the bundled fallback sound"
    [[ "$(cat "$player_log")" == "$tmpdir/Resources/success-sound.mp3" ]] || fail "Codex Stop selected the wrong bundled fallback sound"

    rm -rf "$tmpdir"
    trap - RETURN
}

run_stop_plays_user_job_done_sound_test

echo "PASS"
