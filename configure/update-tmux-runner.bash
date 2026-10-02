#!/usr/bin/env bash

# Source this file so completion changes remain in the calling Bash session.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf '%s\n' 'Run from the repository: source configure/update-tmux-runner.bash' >&2
    exit 2
fi

# Fast-forward the checkout, install, refresh completion, and reload the
# dedicated server without changing the caller's working directory or options.
# Configuration controls use CONFIG_PROMPT; caller arguments are not consumed.
function _tmux_runner_update {
    local repo_root=""
    local config_prompt="${CONFIG_PROMPT:-1}"
    local config_file="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-runner/tmux.conf"
    local completion_file="$HOME/.local/share/bash-completion/completions/tmux-runner"
    local runner_file="$HOME/.local/bin/tmux-runner"
    local socket_file="${TMUX_TMPDIR:-/tmp}/tmux-${UID}/tmux-runner"
    local dependency=""
    local command_path=""
    local session_output=""
    local session_id=""
    local global_prefix=""
    local session_prefix=""
    local -a sessions=()

    case "$config_prompt" in
        0|1) ;;
        *)
            printf '%s\n' 'error: CONFIG_PROMPT must be 0 or 1' >&2
            return 2
            ;;
    esac
    for dependency in git make tmux; do
        if ! command_path=$(command -v "$dependency") || [[ ! -x "$command_path" ]]; then
            printf 'error: %s is not executable\n' "$dependency" >&2
            return 127
        fi
    done
    repo_root=$(git -C "$PWD" rev-parse --show-toplevel) || return
    if [[ ! -f "$repo_root/bin/tmux-runner" || ! -f "$repo_root/config/tmux.conf" ]]; then
        printf '%s\n' 'error: run from the tmux-runner repository' >&2
        return 2
    fi

    git -C "$repo_root" pull --ff-only || return
    make -C "$repo_root" HOME="$HOME" XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-}" \
        CONFIG_PROMPT="$config_prompt" install || return
    # shellcheck disable=SC1090
    source "$completion_file" || return
    "$runner_file" --version || return

    # A stopped server can leave its socket behind. Probe the real server and
    # distinguish a missing listener from permission and command failures.
    if ! session_output=$(LC_ALL=C tmux -L tmux-runner list-sessions -F '#{session_id}' 2>&1); then
        case "$session_output" in
            'no server running on '* | \
                'error connecting to '*' (No such file or directory)' | \
                'error connecting to '*' (Connection refused)')
                printf '%s\n' 'No running tmux-runner server; its next start will load the installed config.'
                return 0
                ;;
            *)
                printf '%s\n' "$session_output" >&2
                return 1
                ;;
        esac
    fi
    if [[ -n "$session_output" ]]; then
        mapfile -t sessions <<< "$session_output"
    fi
    tmux -L tmux-runner source-file "$config_file" || return
    global_prefix=$(tmux -L tmux-runner show-options -gv prefix2) || return
    for session_id in "${sessions[@]}"; do
        tmux -L tmux-runner set-option -u -t "$session_id" prefix2 || return
        session_prefix=$(tmux -L tmux-runner show-options -Av -t "$session_id" prefix2) || return
        if [[ "$session_prefix" != "$global_prefix" ]]; then
            printf 'error: session %s did not inherit prefix2 %s\n' "$session_id" "$global_prefix" >&2
            return 1
        fi
    done
    printf 'Reloaded config on %s; %d session(s) inherit prefix2 %s.\n' \
        "$socket_file" "${#sessions[@]}" "$global_prefix"
}

_tmux_runner_update
