function _tmux_runner_config_file {
    local config_home="${XDG_CONFIG_HOME:-${HOME}/.config}"

    printf '%s/tmux-runner/tmux.conf\n' "$config_home"
}

function _tmux_runner_complete_sessions {
    local current="$1"
    local config_file=""
    local session=""

    config_file=$(_tmux_runner_config_file)
    if [[ ! -e "$config_file" ]]; then
        config_file="/dev/null"
    fi
    while IFS= read -r session; do
        if [[ "$session" == "$current"* ]]; then
            COMPREPLY+=("$session")
        fi
    done < <(
        tmux -L tmux-runner -f "$config_file" \
            list-sessions -F '#{session_name}' 2>/dev/null
    )
}

function _tmux_runner {
    local current="${COMP_WORDS[COMP_CWORD]:-}"
    local previous=""
    local command_name="${COMP_WORDS[1]:-}"

    COMPREPLY=()
    if (( COMP_CWORD > 0 )); then
        previous="${COMP_WORDS[COMP_CWORD - 1]}"
    fi

    if (( COMP_CWORD == 1 )); then
        mapfile -t COMPREPLY < <(
            compgen -W 'create c repo recent last ls attach a -V --version -h --help' -- "$current"
        )
        return
    fi

    case "$command_name" in
        create|c)
            if [[ "$previous" == "-c" ]]; then
                mapfile -t COMPREPLY < <(compgen -d -- "$current")
            elif [[ "$current" == -* ]]; then
                mapfile -t COMPREPLY < <(
                    compgen -W '-s -c -h --help' -- "$current"
                )
            fi
            ;;
        repo|recent|last|ls)
            if [[ "$current" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W '-h --help' -- "$current")
            fi
            ;;
        attach|a)
            if [[ "$previous" == "-t" ]] || [[ "$previous" == "--" ]]; then
                _tmux_runner_complete_sessions "$current"
            elif [[ "$current" == -* ]]; then
                mapfile -t COMPREPLY < <(
                    compgen -W '-t -h --help' -- "$current"
                )
            elif (( COMP_CWORD == 2 )); then
                _tmux_runner_complete_sessions "$current"
            fi
            ;;
    esac
}

complete -F _tmux_runner tmux-runner
