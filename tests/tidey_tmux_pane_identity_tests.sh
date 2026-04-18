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
    PATH="$tmpdir:$PATH" "$@"
    rm -rf "$tmpdir"
}

mock_script="$(mktemp "${TMPDIR:-/tmp}/tidey-tmux-pane-tests-mock.XXXXXX")"
cat > "$mock_script" <<'EOF'
  pane-hit)
    if [[ "$1 $2 $3 $4 $5 $6" == "show-options -p -v -t %42 @tidey_workspace_id" ]]; then
      printf 'workspace-pane\n'
      exit 0
    fi
    if [[ "$1 $2 $3 $4 $5 $6" == "show-options -p -v -t %42 @tidey_panel_id" ]]; then
      printf 'panel-pane\n'
      exit 0
    fi
    exit 1
    ;;
  fallback-global)
    if [[ "$1 $2 $3 $4 $5 $6" == "show-options -p -v -t %42 @tidey_workspace_id" ]]; then
      exit 1
    fi
    if [[ "$1 $2 $3 $4 $5 $6" == "show-options -p -v -t %42 @tidey_panel_id" ]]; then
      exit 1
    fi
    if [[ "$1 $2 $3" == "show-environment TIDEY_WORKSPACE_ID" ]]; then
      printf 'TIDEY_WORKSPACE_ID=workspace-global\n'
      exit 0
    fi
    if [[ "$1 $2 $3" == "show-environment TIDEY_PANEL_ID" ]]; then
      printf 'TIDEY_PANEL_ID=panel-global\n'
      exit 0
    fi
    exit 1
    ;;
  pane-empty-global-unset)
    if [[ "$1 $2 $3 $4 $5 $6" == "show-options -p -v -t %42 @tidey_workspace_id" ]]; then
      printf '\n'
      exit 0
    fi
    if [[ "$1 $2 $3 $4 $5 $6" == "show-options -p -v -t %42 @tidey_panel_id" ]]; then
      printf '\n'
      exit 0
    fi
    if [[ "$1 $2 $3" == "show-environment TIDEY_WORKSPACE_ID" ]]; then
      printf '%s\n' '-TIDEY_WORKSPACE_ID'
      exit 0
    fi
    if [[ "$1 $2 $3" == "show-environment TIDEY_PANEL_ID" ]]; then
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

run_with_tmux_mock "$mock_script" env TIDEY_TMUX_TEST_MODE=fallback-global TMUX_PANE=%42 TIDEY_HELPER_UNDER_TEST="$SCRIPT_DIR/../Resources/bin/tidey-tmux-pane-identity" bash -c '
    set -euo pipefail
    source "$TIDEY_HELPER_UNDER_TEST"
    tidey_hydrate_tmux_pane_identity
    [[ "${TIDEY_WORKSPACE_ID:-}" == "workspace-global" ]] || exit 12
    [[ "${TIDEY_PANEL_ID:-}" == "panel-global" ]] || exit 13
' || fail "fallback-global"

run_with_tmux_mock "$mock_script" env TIDEY_TMUX_TEST_MODE=pane-empty-global-unset TMUX_PANE=%42 TIDEY_WORKSPACE_ID=stale TIDEY_PANEL_ID=stale TIDEY_HELPER_UNDER_TEST="$SCRIPT_DIR/../Resources/bin/tidey-tmux-pane-identity" bash -c '
    set -euo pipefail
    source "$TIDEY_HELPER_UNDER_TEST"
    tidey_hydrate_tmux_pane_identity
    [[ -z "${TIDEY_WORKSPACE_ID+x}" ]] || exit 14
    [[ -z "${TIDEY_PANEL_ID+x}" ]] || exit 15
' || fail "pane-empty-global-unset"

rm -f "$mock_script"
echo "PASS"
