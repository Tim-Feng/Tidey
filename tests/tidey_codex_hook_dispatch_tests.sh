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

# Real hook path: codex-hook-dispatch -> TideyCLI compiled from the current sources -> an
# isolated capture socket. Managed app-server Codex (TIDEY_CODEX_STATUS_OWNER=lifecycle) keeps
# notifications but writes no owner-less shell_state; plain Codex still reports Running/Idle.
run_status_owner_hook_messages_test() {
    local tmpdir
    local bin_dir
    local repo_dir="$SCRIPT_DIR/.."
    local mode
    local capture

    tmpdir="$(mktemp -d "/private/tmp/tidey-codex-hook-owner.XXXXXX")"
    trap 'rm -rf "$tmpdir"' RETURN
    bin_dir="$tmpdir/bin"
    mkdir -p "$bin_dir"
    cp "$DISPATCH_UNDER_TEST" "$bin_dir/codex-hook-dispatch"
    printf 'tidey_hydrate_tmux_pane_identity() { :; }\n' > "$bin_dir/tidey-tmux-pane-identity"
    xcrun swiftc "$repo_dir/sources/TideyCLI/main.swift" "$repo_dir/sources/TideyCLICommandFormatter.swift" \
        -o "$bin_dir/tidey" >"$tmpdir/swiftc.log" 2>&1 ||
        fail "could not compile TideyCLI from current sources: $(tail -5 "$tmpdir/swiftc.log")"

    for mode in plain managed; do
        capture="$tmpdir/$mode.capture"
        python3 - "$tmpdir/$mode.sock" "$capture" "$bin_dir/codex-hook-dispatch" "$mode" "$tmpdir" <<'PY'
import os, socket, subprocess, sys, threading
path, capture, dispatch, mode, home = sys.argv[1:]
server = socket.socket(socket.AF_UNIX)
server.bind(path)
server.listen(16)
server.settimeout(2)
lines = []
def accept():
    try:
        while True:
            connection, _ = server.accept()
            data = b""
            while chunk := connection.recv(65536):
                data += chunk
            lines.extend(line for line in data.decode().splitlines() if line)
    except socket.timeout:
        pass
thread = threading.Thread(target=accept)
thread.start()
env = {k: v for k, v in os.environ.items() if k != "TIDEY_CODEX_STATUS_OWNER"}
env.update(HOME=home, TMPDIR=home, TIDEY_CODEX_HOOKS_ENABLED="1", TIDEY_SOCKET_PATH=path,
           TIDEY_WORKSPACE_ID="workspace-1", TIDEY_PANEL_ID="panel-1",
           TIDEY_COMPLETION_SOUND_PLAYER=os.path.join(home, "no-player"))
if mode == "managed":
    env["TIDEY_CODEX_STATUS_OWNER"] = "lifecycle"
for event in ("user-prompt-submit", "stop"):
    subprocess.run([dispatch, event, '{"last-assistant-message":"Done"}'], env=env, check=True)
thread.join()
server.close()
open(capture, "w").write("\n".join(lines) + "\n")
PY
    done

    grep -qx 'report_shell_state running --workspace_id=workspace-1' "$tmpdir/plain.capture" ||
        fail "plain Codex hook no longer reports Running: $(tr '\n' ';' < "$tmpdir/plain.capture")"
    grep -qx 'report_shell_state prompt --workspace_id=workspace-1' "$tmpdir/plain.capture" ||
        fail "plain Codex hook no longer reports Idle"
    grep -q '"action":"notification.create"' "$tmpdir/plain.capture" ||
        fail "plain Codex Stop lost its notification"
    if grep -q 'report_shell_state' "$tmpdir/managed.capture"; then
        fail "managed Codex hook wrote owner-less shell_state: $(tr '\n' ';' < "$tmpdir/managed.capture")"
    fi
    grep -q '"action":"notification.create"' "$tmpdir/managed.capture" ||
        fail "managed Codex Stop lost its notification"
}

run_stop_plays_user_job_done_sound_test
run_status_owner_hook_messages_test

echo "PASS"
