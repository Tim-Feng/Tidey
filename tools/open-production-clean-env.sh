#!/usr/bin/env bash

set -euo pipefail

tidey_sanitize_production_launch_environment() {
    local env_name

    unset TMUX
    unset TMUX_PANE
    while IFS='=' read -r env_name _; do
        case "$env_name" in
            TIDEY_*) unset "$env_name" ;;
        esac
    done < <(env)
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    tidey_sanitize_production_launch_environment
    exec /usr/bin/open /Applications/Tidey.app
fi
