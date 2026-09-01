#!/usr/bin/env bash

set -euo pipefail

# Installs a missing runner config, optionally confirms replacement of a
# regular file, and preserves links and other non-regular destinations.
function main {
    local source_file=""
    local destination_file=""
    local prompt_mode=""
    local response=""
    local install_bin=""

    if (( $# != 3 )); then
        printf "Usage: %s SOURCE DESTINATION CONFIG_PROMPT\n" "${0##*/}" >&2
        return 2
    fi
    source_file="$1"
    destination_file="$2"
    prompt_mode="$3"

    case "$prompt_mode" in
        0|1)
            ;;
        *)
            printf "error: CONFIG_PROMPT must be 0 or 1\n" >&2
            return 2
            ;;
    esac

    install_bin=$(command -v install || true)
    if [[ -z "$install_bin" ]] || [[ ! -x "$install_bin" ]]; then
        printf "error: install is not executable\n" >&2
        return 1
    fi
    if [[ ! -f "$source_file" ]]; then
        printf "error: config source is not a regular file: %s\n" \
            "$source_file" >&2
        return 1
    fi

    if [[ -L "$destination_file" ]]; then
        printf "Preserved local config symlink: %s\n" "$destination_file"
        return 0
    fi
    if [[ ! -e "$destination_file" ]]; then
        "$install_bin" -m 0644 -- "$source_file" "$destination_file"
        printf "Installed local config: %s\n" "$destination_file"
        return 0
    fi
    if [[ ! -f "$destination_file" ]]; then
        printf "Preserved non-regular local config: %s\n" "$destination_file"
        return 0
    fi
    if [[ "$prompt_mode" == 0 ]]; then
        printf "Preserved existing local config: %s\n" "$destination_file"
        return 0
    fi

    printf "Replace existing local config at %s? [y/N] " "$destination_file"
    if ! IFS= read -r response; then
        response=""
    fi
    case "$response" in
        y|Y)
            "$install_bin" -m 0644 -- "$source_file" "$destination_file"
            printf "Installed local config: %s\n" "$destination_file"
            ;;
        *)
            printf "Preserved existing local config: %s\n" \
                "$destination_file"
            ;;
    esac
}

main "$@"
