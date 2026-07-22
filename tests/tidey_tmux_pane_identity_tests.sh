#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../Resources/bin/tidey-tmux-pane-identity"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_with_tmux_mock() {
    local mock_script="$1"
    shift
    local tmpdir
    local status=0
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/tidey-tmux-pane-tests.XXXXXX")"
    cat > "$tmpdir/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${TIDEY_TMUX_TEST_MODE:-}" in
EOF
    cat "$mock_script" >> "$tmpdir/tmux"
    cat >> "$tmpdir/tmux" <<'EOF'
  *)
    exit 1
    ;;
esac
EOF
    chmod +x "$tmpdir/tmux"
    PATH="$tmpdir:$PATH" "$@" || status=$?
    rm -rf "$tmpdir"
    return "$status"
}

mock_script="$(mktemp "${TMPDIR:-/tmp}/tidey-tmux-pane-tests-mock.XXXXXX")"
cat > "$mock_script" <<'EOF'
  pane-hit)
    if [[ "$*" == "show-options -p -v -t %42 @tidey_workspace_id" ]]; then
      printf 'workspace-pane\n'
      exit 0
    fi
    if [[ "$*" == "show-options -p -v -t %42 @tidey_panel_id" ]]; then
      printf 'panel-pane\n'
      exit 0
    fi
    exit 1
    ;;
  fallback-global)
    if [[ "$*" == "show-options -p -v -t %42 @tidey_workspace_id" ]]; then
      exit 1
    fi
    if [[ "$*" == "show-options -p -v -t %42 @tidey_panel_id" ]]; then
      exit 1
    fi
    if [[ "$*" == "show-environment TIDEY_WORKSPACE_ID" ]]; then
      printf 'TIDEY_WORKSPACE_ID=workspace-global\n'
      exit 0
    fi
    if [[ "$*" == "show-environment TIDEY_PANEL_ID" ]]; then
      printf 'TIDEY_PANEL_ID=panel-global\n'
      exit 0
    fi
    exit 1
    ;;
  runtime-pane-hit)
    if [[ "$*" == "show-options -p -v -t %42 @tidey_socket_path" ]]; then
      printf '/tmp/tidey-pane.sock\n'
      exit 0
    fi
    if [[ "$*" == "show-options -p -v -t %42 @tidey_bin_dir" ]]; then
      printf '/Applications/Tidey Pane.app/Contents/Resources/bin\n'
      exit 0
    fi
    exit 1
    ;;
  runtime-session-fallback)
    if [[ "$*" == "show-options -p -v -t %42 @tidey_socket_path" ]] ||
       [[ "$*" == "show-options -p -v -t %42 @tidey_bin_dir" ]]; then
      exit 1
    fi
    if [[ "$*" == "show-environment -t %42 TIDEY_SOCKET_PATH" ]]; then
      printf 'TIDEY_SOCKET_PATH=/tmp/tidey-session.sock\n'
      exit 0
    fi
    if [[ "$*" == "show-environment -t %42 TIDEY_BIN_DIR" ]]; then
      printf 'TIDEY_BIN_DIR=/Applications/Tidey Session.app/Contents/Resources/bin\n'
      exit 0
    fi
    exit 1
    ;;
  delayed-pane-identity)
    if [[ "$*" == "show-options -p -v -t %42 @tidey_workspace_id" ]]; then
      counter_file="${TIDEY_TMUX_COUNTER_FILE:?}"
      count=0
      if [[ -f "$counter_file" ]]; then
        count="$(<"$counter_file")"
      fi
      count=$((count + 1))
      printf '%s' "$count" > "$counter_file"
      if [[ "$count" -ge 3 ]]; then
        printf 'workspace-delayed\n'
      fi
      exit 0
    fi
    if [[ "$*" == "show-options -p -v -t %42 @tidey_panel_id" ]]; then
      printf 'panel-delayed\n'
      exit 0
    fi
    exit 1
    ;;
  pane-empty-global-unset)
    if [[ "$*" == "show-options -p -v -t %42 @tidey_workspace_id" ]]; then
      printf '\n'
      exit 0
    fi
    if [[ "$*" == "show-options -p -v -t %42 @tidey_panel_id" ]]; then
      printf '\n'
      exit 0
    fi
    if [[ "$*" == "show-environment TIDEY_WORKSPACE_ID" ]]; then
      printf '%s\n' '-TIDEY_WORKSPACE_ID'
      exit 0
    fi
    if [[ "$*" == "show-environment TIDEY_PANEL_ID" ]]; then
      printf '%s\n' '-TIDEY_PANEL_ID'
      exit 0
    fi
    exit 1
    ;;
EOF

run_with_tmux_mock "$mock_script" env TIDEY_TMUX_TEST_MODE=pane-hit TMUX_PANE=%42 TIDEY_HELPER_UNDER_TEST="$SCRIPT_DIR/../Resources/bin/tidey-tmux-pane-identity" bash -c '
    set -euo pipefail
    source "$TIDEY_HELPER_UNDER_TEST"
    tidey_hydrate_tmux_pane_identity
    [[ "${TIDEY_WORKSPACE_ID:-}" == "workspace-pane" ]] || exit 10
    [[ "${TIDEY_PANEL_ID:-}" == "panel-pane" ]] || exit 11
' || fail "pane-hit"

if run_with_tmux_mock "$mock_script" env -u TIDEY_WORKSPACE_ID -u TIDEY_PANEL_ID TIDEY_TMUX_TEST_MODE=fallback-global TMUX_PANE=%42 TIDEY_HELPER_UNDER_TEST="$SCRIPT_DIR/../Resources/bin/tidey-tmux-pane-identity" bash -c '
    set -euo pipefail
    source "$TIDEY_HELPER_UNDER_TEST"
    tidey_hydrate_tmux_pane_identity
    [[ -z "${TIDEY_WORKSPACE_ID+x}" ]] || exit 12
    [[ -z "${TIDEY_PANEL_ID+x}" ]] || exit 13
'; then
    :
else
    fail "identity-must-not-fallback-to-session-environment"
fi

run_with_tmux_mock "$mock_script" env TIDEY_TMUX_TEST_MODE=pane-empty-global-unset TMUX_PANE=%42 TIDEY_WORKSPACE_ID=stale TIDEY_PANEL_ID=stale TIDEY_HELPER_UNDER_TEST="$SCRIPT_DIR/../Resources/bin/tidey-tmux-pane-identity" bash -c '
    set -euo pipefail
    source "$TIDEY_HELPER_UNDER_TEST"
    tidey_hydrate_tmux_pane_identity
    [[ -z "${TIDEY_WORKSPACE_ID+x}" ]] || exit 14
    [[ -z "${TIDEY_PANEL_ID+x}" ]] || exit 15
' || fail "pane-empty-global-unset"

run_with_tmux_mock "$mock_script" env -u TIDEY_SOCKET_PATH -u TIDEY_BIN_DIR TIDEY_TMUX_TEST_MODE=runtime-pane-hit TMUX_PANE=%42 TIDEY_HELPER_UNDER_TEST="$SCRIPT_DIR/../Resources/bin/tidey-tmux-pane-identity" bash -c '
    set -euo pipefail
    source "$TIDEY_HELPER_UNDER_TEST"
    tidey_hydrate_tmux_runtime_environment
    [[ "${TIDEY_SOCKET_PATH:-}" == "/tmp/tidey-pane.sock" ]] || exit 16
    [[ "${TIDEY_BIN_DIR:-}" == "/Applications/Tidey Pane.app/Contents/Resources/bin" ]] || exit 17
' || fail "runtime-pane-hit"

run_with_tmux_mock "$mock_script" env -u TIDEY_SOCKET_PATH -u TIDEY_BIN_DIR TIDEY_TMUX_TEST_MODE=runtime-session-fallback TMUX_PANE=%42 TIDEY_HELPER_UNDER_TEST="$SCRIPT_DIR/../Resources/bin/tidey-tmux-pane-identity" bash -c '
    set -euo pipefail
    source "$TIDEY_HELPER_UNDER_TEST"
    tidey_hydrate_tmux_runtime_environment
    [[ "${TIDEY_SOCKET_PATH:-}" == "/tmp/tidey-session.sock" ]] || exit 18
    [[ "${TIDEY_BIN_DIR:-}" == "/Applications/Tidey Session.app/Contents/Resources/bin" ]] || exit 19
' || fail "runtime-session-fallback"

counter_file="$(mktemp "${TMPDIR:-/tmp}/tidey-tmux-pane-counter.XXXXXX")"
printf '0' > "$counter_file"
run_with_tmux_mock "$mock_script" env -u TIDEY_WORKSPACE_ID -u TIDEY_PANEL_ID TIDEY_TMUX_TEST_MODE=delayed-pane-identity TIDEY_TMUX_COUNTER_FILE="$counter_file" TMUX_PANE=%42 TIDEY_TMUX_IDENTITY_WAIT_ATTEMPTS=4 TIDEY_TMUX_IDENTITY_WAIT_INTERVAL=0 TIDEY_HELPER_UNDER_TEST="$SCRIPT_DIR/../Resources/bin/tidey-tmux-pane-identity" bash -c '
    set -euo pipefail
    source "$TIDEY_HELPER_UNDER_TEST"
    tidey_wait_for_tmux_pane_identity
    [[ "${TIDEY_WORKSPACE_ID:-}" == "workspace-delayed" ]] || exit 20
    [[ "${TIDEY_PANEL_ID:-}" == "panel-delayed" ]] || exit 21
' || fail "delayed-pane-identity"
rm -f "$counter_file"

rm -f "$mock_script"
echo "PASS"
