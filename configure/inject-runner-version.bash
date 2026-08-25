#!/usr/bin/env bash

# Injects immutable Git and installation metadata into an installed runner.

set -euo pipefail

# The explicit source repository is the only Git identity authority.
unset GIT_DIR GIT_WORK_TREE

readonly PROGRAM_NAME="${0##*/}"

function fail {
    local message="$1"

    printf '%s: %s\n' "$PROGRAM_NAME" "$message" >&2
    return 2
}

function require_metadata_anchor {
    local destination="$1"
    local variable_name="$2"
    local line=""
    local count=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "readonly ${variable_name}="* ]]; then
            count=$((count + 1))
        fi
    done < "$destination"
    if (( count != 1 )); then
        fail "expected exactly one readonly ${variable_name} declaration in ${destination}; found ${count}"
        return
    fi
}

function main {
    local destination=""
    local repository=""
    local git_bin=""
    local date_bin=""
    local sed_bin=""
    local git_hash="unknown"
    local commit_timestamp=""
    local commit_date="unknown"
    local install_date=""

    if (( $# != 2 )); then
        fail "usage: $PROGRAM_NAME <installed-runner> <source-repository>"
        return
    fi
    destination="$1"
    repository="$2"

    if [[ ! -f "$destination" ]] || [[ ! -w "$destination" ]]; then
        fail "installed runner is not a writable file: $destination"
        return
    fi
    if [[ ! -d "$repository" ]]; then
        fail "source repository is not a directory: $repository"
        return
    fi
    require_metadata_anchor "$destination" RUNNER_GIT_HASH || return
    require_metadata_anchor "$destination" RUNNER_COMMIT_DATE || return
    require_metadata_anchor "$destination" RUNNER_INSTALL_DATE || return

    date_bin=$(type -P date || true)
    sed_bin=$(type -P sed || true)
    if [[ -z "$date_bin" ]] || [[ ! -x "$date_bin" ]]; then
        fail "date is not available in PATH"
        return
    fi
    if [[ -z "$sed_bin" ]] || [[ ! -x "$sed_bin" ]]; then
        fail "sed is not available in PATH"
        return
    fi

    git_bin=$(type -P git || true)
    if [[ -n "$git_bin" ]] && [[ -x "$git_bin" ]]; then
        git_hash=$(
            "$git_bin" -C "$repository" rev-parse --short HEAD \
                2>/dev/null || printf '%s' "unknown"
        )
        if [[ "$git_hash" != "unknown" ]] && \
            ! "$git_bin" -C "$repository" diff --quiet HEAD -- \
                2>/dev/null; then
            git_hash="${git_hash}-dirty"
        fi
        commit_timestamp=$(
            "$git_bin" -C "$repository" show -s --format=%ct HEAD \
                2>/dev/null || true
        )
    fi

    if [[ -n "$commit_timestamp" ]]; then
        if ! commit_date=$(
            "$date_bin" -u -d "@${commit_timestamp}" '+%Y-%m-%dT%H:%M:%SZ'
        ); then
            commit_date="unknown"
        fi
    fi
    install_date=$("$date_bin" -u '+%Y-%m-%dT%H:%M:%SZ')

    "$sed_bin" -i \
        -e "s/^readonly RUNNER_GIT_HASH=.*/readonly RUNNER_GIT_HASH=\"${git_hash}\"/" \
        -e "s/^readonly RUNNER_COMMIT_DATE=.*/readonly RUNNER_COMMIT_DATE=\"${commit_date}\"/" \
        -e "s/^readonly RUNNER_INSTALL_DATE=.*/readonly RUNNER_INSTALL_DATE=\"${install_date}\"/" \
        "$destination"
}

main "$@"
