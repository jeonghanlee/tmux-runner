#!/usr/bin/env bash

set -euo pipefail

# Each test process establishes Git identity from its explicit fixtures.
TEST_INITIAL_GIT_DIR=${GIT_DIR-}
TEST_INITIAL_GIT_WORK_TREE=${GIT_WORK_TREE-}
unset GIT_DIR GIT_WORK_TREE
readonly TEST_INITIAL_GIT_DIR TEST_INITIAL_GIT_WORK_TREE

TEST_SOURCE=${BASH_SOURCE[0]}
if [[ "$TEST_SOURCE" == */* ]]; then
    TEST_SOURCE_DIR=${TEST_SOURCE%/*}
else
    TEST_SOURCE_DIR=.
fi
TEST_DIR=$(cd -- "$TEST_SOURCE_DIR" && pwd -P)
readonly TEST_DIR
unset TEST_SOURCE TEST_SOURCE_DIR
REPO_ROOT=$(cd -- "$TEST_DIR/.." && pwd -P)
readonly REPO_ROOT
readonly SOURCE_RUNNER="$REPO_ROOT/bin/tmux-runner"
readonly SOURCE_COMPLETION="$REPO_ROOT/bin/tmux-runner-completion.bash"
RUNNER=${TMUX_RUNNER_TEST_RUNNER:-$SOURCE_RUNNER}
readonly RUNNER
COMPLETION=${TMUX_RUNNER_TEST_COMPLETION:-$SOURCE_COMPLETION}
readonly COMPLETION
TEST_VARIANT=${TMUX_RUNNER_TEST_VARIANT:-source}
readonly TEST_VARIANT
readonly VERSION_INJECTOR="$REPO_ROOT/configure/inject-runner-version.bash"
readonly README="$REPO_ROOT/README.md"
readonly RUNNER_CONFIG="$REPO_ROOT/config/tmux.conf"
readonly RUNNER_SERVER_NAME="tmux-runner"
readonly SESSION_PATH_UNMARKED_MARKER="tmux-runner-unmarked"
readonly SESSION_PATH_GLOBAL_FALLBACK_MARKER="tmux-runner-global-unset"
readonly SESSION_ENTRY_HOOK_PREFIX="@tmux-runner-entry-"
readonly AFTER_SET_OPTION_SENTINEL="@tmux-runner-after-set-option-fired"
readonly PTY_TIMEOUT_SECONDS=12
readonly POLL_INTERVAL_SECONDS=0.05
readonly SUPERVISOR_TIMEOUT_SECONDS=30

TMUX_PATH=""
TMUX_RUNNER_TRACE_PREFIX=""
WORKSPACE=""
CURRENT_PTY_PID=""
CURRENT_PTY_FD=""
LAST_TRANSCRIPT=""
LAST_CONSOLE=""
LAST_FIFO=""
LAST_PTY_RC=0
LAST_INSIDE_TRACE=""
LAST_INSIDE_STATUS=""
NEW_TMUX_ROOT=""
STATE_MONITOR_PID=""
STATE_MONITOR_STOP=""
STATE_MONITOR_REPORT=""
STATE_MONITOR_READY=""
STATE_MONITOR_SEQUENCE=0
STATE_RECORD_MONITOR_PID=""
STATE_RECORD_MONITOR_STOP=""
STATE_RECORD_MONITOR_REPORT=""
STATE_RECORD_MONITOR_READY=""
STATE_LOCK_HOLDER_PID=""
STATE_LOCK_HOLDER_RELEASE=""
STATE_LOCK_HOLDER_READY=""
ATTACH_GATE_RELEASE=""
ATTACH_GATE_READY=""
ENTRY_GATE_RELEASE=""
ENTRY_GATE_READY=""
ENTRY_GATE_DONE=""
LAST_PENDING_FILE=""
BATCH_PTY_PIDS=()
BATCH_PTY_FDS=()
BATCH_SESSION_NAMES=()
TESTS_PASSED=0
TMUX_ROOTS=()
EXTRA_PTY_PIDS=()
EXTRA_PTY_FDS=()

function require_test_process_git_boundary {
    local expected_repository="${TMUX_RUNNER_TEST_EXPECTED_AMBIENT_REPOSITORY:-}"

    if [[ -z "$expected_repository" ]]; then
        return 0
    fi
    if [[ "$TEST_INITIAL_GIT_DIR" != "$expected_repository/.git" ]] || \
        [[ "$TEST_INITIAL_GIT_WORK_TREE" != "$expected_repository" ]]; then
        fail_test "test process did not receive the controlled ambient Git identity"
    fi
}

function close_fd_number {
    local fd_number="$1"

    if [[ "$fd_number" =~ ^[0-9]+$ ]]; then
        exec {fd_number}>&-
    fi
}

function terminate_pty_process {
    local pid="$1"
    local deadline=$((SECONDS + 2))

    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
        while kill -0 "$pid" 2>/dev/null && (( SECONDS <= deadline )); do
            sleep "$POLL_INTERVAL_SECONDS"
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
        fi
    fi
    wait "$pid" 2>/dev/null || true
}

function record_manifest {
    local record_type="$1"
    local record_value="$2"

    if [[ -n "${TMUX_RUNNER_TEST_MANIFEST:-}" ]]; then
        printf '%s\t%s\n' "$record_type" "$record_value" \
            >> "$TMUX_RUNNER_TEST_MANIFEST"
    fi
}

function cleanup {
    local exit_status="${1:-0}"
    local root=""
    local cleanup_pid=""
    local extra_pid=""
    local extra_fd=""
    local server_pid=""
    local deadline=0

    set +e
    if [[ -n "$STATE_RECORD_MONITOR_PID" ]]; then
        if [[ -n "$STATE_RECORD_MONITOR_STOP" ]]; then
            : > "$STATE_RECORD_MONITOR_STOP"
        fi
        terminate_pty_process "$STATE_RECORD_MONITOR_PID"
    fi
    if [[ -n "$STATE_LOCK_HOLDER_PID" ]]; then
        if [[ -n "$STATE_LOCK_HOLDER_RELEASE" ]]; then
            : > "$STATE_LOCK_HOLDER_RELEASE"
        fi
        terminate_pty_process "$STATE_LOCK_HOLDER_PID"
    fi
    if [[ -n "$STATE_MONITOR_PID" ]]; then
        if [[ -n "$STATE_MONITOR_STOP" ]]; then
            : > "$STATE_MONITOR_STOP"
        fi
        terminate_pty_process "$STATE_MONITOR_PID"
    fi
    close_current_pty_input
    for extra_fd in "${EXTRA_PTY_FDS[@]}"; do
        close_fd_number "$extra_fd"
    done
    cleanup_pid="$CURRENT_PTY_PID"
    if [[ -n "$cleanup_pid" ]]; then
        terminate_pty_process "$cleanup_pid"
    fi
    for extra_pid in "${EXTRA_PTY_PIDS[@]}"; do
        terminate_pty_process "$extra_pid"
    done
    for root in "${TMUX_ROOTS[@]}"; do
        server_pid=$(env -u TMUX TMUX_TMPDIR="$root" \
            tmux -L "$RUNNER_SERVER_NAME" display-message -p '#{pid}' \
            2>/dev/null || true)
        if [[ "$server_pid" =~ ^[0-9]+$ ]]; then
            record_manifest pid "$server_pid"
        fi
        env -u TMUX TMUX_TMPDIR="$root" tmux -L "$RUNNER_SERVER_NAME" \
            kill-server >/dev/null 2>&1
        if [[ "$server_pid" =~ ^[0-9]+$ ]]; then
            deadline=$((SECONDS + 2))
            while kill -0 "$server_pid" 2>/dev/null && \
                (( SECONDS <= deadline )); do
                sleep "$POLL_INTERVAL_SECONDS"
            done
        fi
        rm -f -- "$root/tmux-$UID/$RUNNER_SERVER_NAME"
        server_pid=$(env -u TMUX TMUX_TMPDIR="$root" \
            tmux display-message -p '#{pid}' 2>/dev/null || true)
        if [[ "$server_pid" =~ ^[0-9]+$ ]]; then
            record_manifest pid "$server_pid"
        fi
        env -u TMUX TMUX_TMPDIR="$root" tmux kill-server >/dev/null 2>&1
        if [[ "$server_pid" =~ ^[0-9]+$ ]]; then
            deadline=$((SECONDS + 2))
            while kill -0 "$server_pid" 2>/dev/null && \
                (( SECONDS <= deadline )); do
                sleep "$POLL_INTERVAL_SECONDS"
            done
        fi
        rm -f -- "$root/tmux-$UID/default"
    done
    if (( exit_status == 0 )) && [[ -n "$WORKSPACE" ]] && \
        [[ -d "$WORKSPACE" ]] && \
        [[ "$WORKSPACE" == /tmp/tmux-runner-test.* ]]; then
        chmod -R u+w -- "$WORKSPACE" 2>/dev/null || true
        rm -rf -- "$WORKSPACE"
    elif [[ -n "$WORKSPACE" ]] && [[ -d "$WORKSPACE" ]]; then
        printf 'Diagnostic workspace: %s\n' "$WORKSPACE" >&2
    fi
    if [[ -n "${TMUX_RUNNER_TEST_CLEANUP_DONE:-}" ]]; then
        printf 'done\n' > "$TMUX_RUNNER_TEST_CLEANUP_DONE"
    fi
}

trap 'cleanup "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

function fail_test {
    local message="$1"

    printf 'FAIL: %s\n' "$message" >&2
    if [[ -n "$LAST_TRANSCRIPT" ]] && [[ -f "$LAST_TRANSCRIPT" ]]; then
        printf 'Last PTY transcript:\n' >&2
        tail -n 120 "$LAST_TRANSCRIPT" >&2
    fi
    if [[ -n "$LAST_CONSOLE" ]] && [[ -f "$LAST_CONSOLE" ]]; then
        printf 'Last PTY console:\n' >&2
        tail -n 120 "$LAST_CONSOLE" >&2
    fi
    exit 1
}

function pass_test {
    local label="$1"
    local summary="$2"

    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf 'PASS %s: %s\n' "$label" "$summary"
}

function assert_equal {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [[ "$actual" != "$expected" ]]; then
        printf 'Expected:\n%s\nActual:\n%s\n' "$expected" "$actual" >&2
        fail_test "$message"
    fi
}

function assert_not_equal {
    local unexpected="$1"
    local actual="$2"
    local message="$3"

    if [[ "$actual" == "$unexpected" ]]; then
        fail_test "$message"
    fi
}

function assert_contains {
    local file="$1"
    local text="$2"
    local message="$3"

    if ! grep -F -- "$text" "$file" >/dev/null; then
        fail_test "$message"
    fi
}

function assert_not_contains {
    local file="$1"
    local text="$2"
    local message="$3"

    if grep -F -- "$text" "$file" >/dev/null; then
        fail_test "$message"
    fi
}

function assert_text_not_contains {
    local value="$1"
    local text="$2"
    local message="$3"

    if [[ "$value" == *"$text"* ]]; then
        fail_test "$message"
    fi
}

function assert_command_succeeds {
    local message="$1"

    shift
    if ! "$@"; then
        fail_test "$message"
    fi
}

function require_dependencies {
    local dependency=""
    local dependency_path=""
    local -a dependencies=(
        bash shellcheck tmux script timeout setsid make install cmp stat find sort
        awk grep sed tr env mkdir chmod rm mkfifo mktemp tee tail sleep flock
        hostname git sha256sum date cp ln mv
    )

    for dependency in "${dependencies[@]}"; do
        dependency_path=$(type -P "$dependency" || true)
        if [[ -z "$dependency_path" ]] || [[ ! -x "$dependency_path" ]]; then
            fail_test "required command is not executable: $dependency"
        fi
    done
    for dependency_path in /usr/bin/env /bin/bash /bin/sh; do
        if [[ ! -x "$dependency_path" ]]; then
            fail_test "required command is not executable: $dependency_path"
        fi
    done
    TMUX_PATH=$(type -P tmux)
    TMUX_RUNNER_TRACE_PREFIX="$TMUX_PATH -L $RUNNER_SERVER_NAME -f /dev/null"
}

function create_tmux_root {
    local label="$1"

    NEW_TMUX_ROOT="$WORKSPACE/$label/tmux-root"
    mkdir -p -- "$NEW_TMUX_ROOT"
    chmod 0700 "$NEW_TMUX_ROOT"
    TMUX_ROOTS+=("$NEW_TMUX_ROOT")
    record_manifest root "$NEW_TMUX_ROOT"
}

function run_tmux {
    local root="$1"

    shift
    env -u TMUX TMUX_TMPDIR="$root" \
        tmux -L "$RUNNER_SERVER_NAME" "$@"
}

function run_default_tmux {
    local root="$1"

    shift
    env -u TMUX TMUX_TMPDIR="$root" tmux "$@"
}

function session_names {
    local root="$1"

    run_tmux "$root" list-sessions -F '#{session_name}' | LC_ALL=C sort
}

function server_fingerprint {
    local root="$1"

    run_tmux "$root" list-panes -a \
        -F '#{session_name}|#{session_id}|#{window_id}|#{pane_id}|#{pane_current_path}|#{@tmux-runner-path}' | \
        LC_ALL=C sort
}

function server_identity_fingerprint {
    local root="$1"

    run_tmux "$root" list-panes -a \
        -F '#{session_name}|#{session_id}|#{window_id}|#{pane_id}|#{pane_current_path}' | \
        LC_ALL=C sort
}

function session_identity {
    local root="$1"
    local session_name="$2"

    run_tmux "$root" list-panes -t "=$session_name" -F \
        '#{session_id}|#{window_id}|#{pane_id}'
}

function session_id {
    local root="$1"
    local session_name="$2"

    run_tmux "$root" display-message -p -t "=$session_name:" \
        '#{session_id}'
}

function raw_session_path_marker {
    local root="$1"
    local session_name="$2"

    run_tmux "$root" show-options -v -t "=$session_name:" \
        @tmux-runner-path
}

function entry_hook_name_from_trace {
    local trace_file="$1"
    local trace_line=""

    while IFS= read -r trace_line || [[ -n "$trace_line" ]]; do
        if [[ "$trace_line" =~ SESSION_ENTRY_HOOK_NAME=(@tmux-runner-entry-[A-Za-z0-9_-]+) ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "$trace_file"
    return 1
}

function entry_transaction_id_from_trace {
    local trace_file="$1"
    local hook_name=""
    local trace_line=""
    local transaction_id=""

    if ! hook_name=$(entry_hook_name_from_trace "$trace_file"); then
        return 1
    fi
    transaction_id="${hook_name#"$SESSION_ENTRY_HOOK_PREFIX"}"

    while IFS= read -r trace_line || [[ -n "$trace_line" ]]; do
        if [[ "$trace_line" == *"STATE_TRANSACTION_ID=$transaction_id"* ]]; then
            printf '%s\n' "$transaction_id"
            return 0
        fi
    done < "$trace_file"
    return 1
}

function session_entry_hook_definitions {
    local root="$1"
    local global_hooks=""
    local session_hooks=""
    local session_targets=""
    local session_target=""
    local hook_line=""

    if ! global_hooks=$(run_tmux "$root" show-hooks -g); then
        fail_test "cannot query global tmux hooks"
    fi
    while IFS= read -r hook_line || [[ -n "$hook_line" ]]; do
        if [[ "$hook_line" == "$SESSION_ENTRY_HOOK_PREFIX"* ]]; then
            printf 'global|%s\n' "$hook_line"
        fi
    done <<< "$global_hooks"

    if ! session_targets=$(run_tmux "$root" list-sessions -F '#{session_id}'); then
        fail_test "cannot query tmux sessions for entry hook cleanup"
    fi
    while IFS= read -r session_target || [[ -n "$session_target" ]]; do
        if [[ -z "$session_target" ]]; then
            continue
        fi
        if ! session_hooks=$(run_tmux "$root" show-hooks \
                -t "${session_target}:"); then
            fail_test "cannot query tmux session hooks: $session_target"
        fi
        while IFS= read -r hook_line || [[ -n "$hook_line" ]]; do
            if [[ "$hook_line" == "$SESSION_ENTRY_HOOK_PREFIX"* ]]; then
                printf '%s|%s\n' "$session_target" "$hook_line"
            fi
        done <<< "$session_hooks"
    done <<< "$session_targets"
}

function assert_no_session_entry_hooks {
    local root="$1"
    local message="$2"
    local definitions=""

    definitions=$(session_entry_hook_definitions "$root")
    assert_equal "" "$definitions" "$message"
}

function assert_session_entry_hook_trace {
    local trace_file="$1"
    local root="$2"
    local message="$3"
    local hook_name=""
    local transaction_id=""

    if ! hook_name=$(entry_hook_name_from_trace "$trace_file"); then
        fail_test "$message"
    fi
    if ! transaction_id=$(entry_transaction_id_from_trace "$trace_file"); then
        fail_test "$message"
    fi
    assert_equal "${SESSION_ENTRY_HOOK_PREFIX}${transaction_id}" \
        "$hook_name" "$message"
    assert_no_session_entry_hooks "$root" "$message"
}

function assert_entry_command_targets_id {
    local trace_file="$1"
    local target_id="$2"
    local message="$3"
    local transaction_id=""
    local hook_name=""
    local definition_fragment=""
    local run_fragment=""
    local self_cleanup_fragment=""
    local outer_cleanup_fragment=""
    local guard_fragment=""
    local attach_fragment=""
    local switch_fragment=""
    local fallback_command_fragment=""
    local definition_pattern=""
    local fallback_pattern=""
    local attach_pattern=""
    local switch_pattern=""
    local trace_line=""
    local normalized_line=""

    if ! transaction_id=$(entry_transaction_id_from_trace "$trace_file"); then
        fail_test "$message"
    fi
    hook_name="${SESSION_ENTRY_HOOK_PREFIX}${transaction_id}"
    definition_fragment="set-hook -t ${target_id}: $hook_name"
    self_cleanup_fragment="set-hook -u -t ${target_id}: $hook_name ;"
    run_fragment="set-hook -R -t ${target_id}: $hook_name ;"
    outer_cleanup_fragment="set-hook -u -t ${target_id}: $hook_name"
    guard_fragment="if-shell -F -t ${target_id}:"
    fallback_command_fragment="set-option -gq @tmux-runner-path"
    attach_fragment="attach-session -t $target_id ; run-shell"
    switch_fragment="switch-client -t $target_id ; run-shell"
    definition_pattern="*${definition_fragment}*${self_cleanup_fragment}*"
    definition_pattern+="${fallback_command_fragment}*"
    fallback_pattern="*${fallback_command_fragment}*"
    fallback_pattern+="${SESSION_PATH_GLOBAL_FALLBACK_MARKER}*"
    fallback_pattern+="${guard_fragment}*"
    attach_pattern="*${guard_fragment}*${attach_fragment}*"
    attach_pattern+="${run_fragment}*${outer_cleanup_fragment}*"
    switch_pattern="*${guard_fragment}*${switch_fragment}*"
    switch_pattern+="${run_fragment}*${outer_cleanup_fragment}*"
    while IFS= read -r trace_line || [[ -n "$trace_line" ]]; do
        normalized_line="${trace_line//\\/}"
        normalized_line="${normalized_line//\'/}"
        # The composed trace patterns intentionally retain wildcard separators.
        # shellcheck disable=SC2053
        if [[ "$normalized_line" != $definition_pattern ]]; then
            continue
        fi
        # shellcheck disable=SC2053
        if [[ "$normalized_line" != $fallback_pattern ]]; then
            continue
        fi
        # shellcheck disable=SC2053
        if [[ "$normalized_line" == $attach_pattern ]] || \
            [[ "$normalized_line" == $switch_pattern ]]; then
            return 0
        fi
    done < "$trace_file"
    fail_test "$message"
}

function assert_session_entry_trace_with_prefix {
    local trace_file="$1"
    local root="$2"
    local session_name="$3"
    local trace_prefix="$4"
    local message="$5"
    local target_id=""

    target_id=$(session_id "$root" "$session_name")
    assert_contains "$trace_file" \
        "$trace_prefix set-hook -t '$target_id:' $SESSION_ENTRY_HOOK_PREFIX" \
        "$message"
    assert_entry_command_targets_id "$trace_file" "$target_id" "$message"
    assert_session_entry_hook_trace "$trace_file" "$root" "$message"
}

function assert_session_entry_trace {
    local trace_file="$1"
    local root="$2"
    local session_name="$3"
    local message="$4"

    local target_id=""

    target_id=$(session_id "$root" "$session_name")
    assert_entry_command_targets_id "$trace_file" "$target_id" "$message"
    assert_session_entry_hook_trace "$trace_file" "$root" "$message"
}

function pane_directory {
    local root="$1"
    local session_name="$2"

    run_tmux "$root" list-panes -t "=$session_name" -F \
        '#{pane_current_path}'
}

function decode_session_path_marker {
    local marker="$1"
    local encoded=""
    local decoded=""
    local character=""

    if [[ "$marker" != v1:* ]]; then
        printf '%s' "$marker"
        return 0
    fi
    encoded="${marker#v1:}"
    while [[ -n "$encoded" ]]; do
        case "$encoded" in
            %25*)
                decoded="${decoded}%"
                encoded="${encoded:3}"
                ;;
            %0D*)
                decoded="${decoded}"$'\r'
                encoded="${encoded:3}"
                ;;
            %09*)
                decoded="${decoded}"$'\t'
                encoded="${encoded:3}"
                ;;
            %0A*)
                decoded="${decoded}"$'\n'
                encoded="${encoded:3}"
                ;;
            %*)
                return 1
                ;;
            *)
                character="${encoded:0:1}"
                decoded="${decoded}${character}"
                encoded="${encoded:1}"
                ;;
        esac
    done
    printf '%s' "$decoded"
}

function session_path {
    local root="$1"
    local session_name="$2"
    local marker=""

    marker=$(run_tmux "$root" show-options -qv -t "=$session_name:" \
        @tmux-runner-path)
    decode_session_path_marker "$marker"
}

function session_name_for_path {
    local root="$1"
    local expected_path="$2"
    local session_name=""
    local marked_path=""

    while IFS= read -r session_name; do
        marked_path=$(run_tmux "$root" show-options -qv \
            -t "=$session_name:" \
            @tmux-runner-path 2>/dev/null || true)
        marked_path=$(decode_session_path_marker "$marked_path")
        if [[ "$marked_path" == "$expected_path" ]]; then
            printf '%s\n' "$session_name"
        fi
    done < <(session_names "$root")
}

function init_git_repository {
    local repository="$1"

    mkdir -p -- "$repository"
    git -C "$repository" init -q
    # Test fixtures must not inherit repository hooks from Git templates.
    git -C "$repository" config core.hooksPath /dev/null
    git -C "$repository" config user.name "tmux-runner test"
    git -C "$repository" config user.email "tmux-runner@example.invalid"
    printf 'fixture\n' > "$repository/fixture.txt"
    git -C "$repository" add fixture.txt
    git -C "$repository" commit -q -m "Create test fixture"
}

function close_current_pty_input {
    if [[ -n "$CURRENT_PTY_FD" ]]; then
        exec {CURRENT_PTY_FD}>&-
        CURRENT_PTY_FD=""
    fi
}

function start_pty_command {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local command_string=""

    shift 4
    if [[ -n "$CURRENT_PTY_PID" ]]; then
        fail_test "a PTY is already active"
    fi

    LAST_FIFO="$WORKSPACE/pty/$label.fifo"
    LAST_TRANSCRIPT="$WORKSPACE/pty/$label.typescript"
    LAST_CONSOLE="$WORKSPACE/pty/$label.console"
    mkfifo -- "$LAST_FIFO"
    printf -v command_string '%q ' "$@"
    command_string="${command_string% }"

    setsid env -u TMUX HOME="$home" XDG_CONFIG_HOME="$xdg_home" \
        TMUX_TMPDIR="$root" SHELL=/bin/bash \
        timeout --foreground -k 2s "${PTY_TIMEOUT_SECONDS}s" \
        script -q -e -f -c "$command_string" "$LAST_TRANSCRIPT" \
        < "$LAST_FIFO" > "$LAST_CONSOLE" 2>&1 &
    CURRENT_PTY_PID=$!
    record_manifest pid "$CURRENT_PTY_PID"
    exec {CURRENT_PTY_FD}>"$LAST_FIFO"
}

function start_runner_outside {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local runner="$5"

    shift 5
    start_pty_command "$label" "$root" "$home" "$xdg_home" \
        bash -x "$runner" "$@"
}

function send_current_input {
    local input="$1"

    if [[ -z "$CURRENT_PTY_FD" ]]; then
        fail_test "no PTY input is open"
    fi
    printf '%b' "$input" >&"$CURRENT_PTY_FD"
}

function detach_current_client {
    send_current_input '\002d'
}

function finish_current_pty {
    local rc=0

    if [[ -z "$CURRENT_PTY_PID" ]]; then
        fail_test "no PTY process is active"
    fi
    wait "$CURRENT_PTY_PID" || rc=$?
    close_current_pty_input
    CURRENT_PTY_PID=""
    LAST_PTY_RC=$rc
}

function assert_last_pty_succeeded {
    local message="$1"

    if (( LAST_PTY_RC != 0 )); then
        printf 'PTY console:\n' >&2
        sed -n '1,160p' "$LAST_CONSOLE" >&2
        fail_test "$message (exit $LAST_PTY_RC)"
    fi
}

function assert_last_pty_failed_without_timeout {
    local message="$1"

    if (( LAST_PTY_RC == 0 )); then
        fail_test "$message (unexpected success)"
    fi
    if (( LAST_PTY_RC == 124 || LAST_PTY_RC == 137 )); then
        fail_test "$message (timed out)"
    fi
}

function wait_for_transcript_text {
    local text="$1"
    local deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))

    while (( SECONDS <= deadline )); do
        if [[ -f "$LAST_TRANSCRIPT" ]] && \
            grep -F -- "$text" "$LAST_TRANSCRIPT" >/dev/null; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

function wait_for_file_text {
    local file="$1"
    local text="$2"
    local deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))

    while (( SECONDS <= deadline )); do
        if [[ -f "$file" ]] && grep -F -- "$text" "$file" >/dev/null; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

function wait_for_file {
    local file="$1"
    local deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))

    while (( SECONDS <= deadline )); do
        if [[ -s "$file" ]]; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

function wait_for_named_file_count {
    local directory="$1"
    local name_pattern="$2"
    local maximum_depth="$3"
    local expected_count="$4"
    local count=0
    local deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))

    while (( SECONDS <= deadline )); do
        if [[ -d "$directory" ]]; then
            count=$(find "$directory" -mindepth 1 \
                -maxdepth "$maximum_depth" -type f \
                -name "$name_pattern" -size +0c -print | \
                awk 'END { print NR + 0 }')
            if (( count == expected_count )); then
                return 0
            fi
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

function wait_for_path_absent {
    local path="$1"
    local deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))

    while (( SECONDS <= deadline )); do
        if [[ ! -e "$path" ]]; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

function wait_for_client_session {
    local root="$1"
    local expected_session="$2"
    local clients=""
    local deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))

    while (( SECONDS <= deadline )); do
        clients=$(run_tmux "$root" list-clients \
            -F '#{client_session}' 2>/dev/null || true)
        if grep -Fx -- "$expected_session" <<< "$clients" >/dev/null; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

function wait_for_default_client_session {
    local root="$1"
    local expected_session="$2"
    local clients=""
    local deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))

    while (( SECONDS <= deadline )); do
        clients=$(run_default_tmux "$root" list-clients \
            -F '#{client_session}' 2>/dev/null || true)
        if grep -Fx -- "$expected_session" <<< "$clients" >/dev/null; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

function wait_for_client_count {
    local root="$1"
    local expected_session="$2"
    local expected_count="$3"
    local client=""
    local count=0
    local deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))
    local -a client_sessions=()

    while (( SECONDS <= deadline )); do
        mapfile -t client_sessions < <(current_client_sessions "$root")
        count=0
        for client in "${client_sessions[@]}"; do
            if [[ "$client" == "$expected_session" ]]; then
                count=$((count + 1))
            fi
        done
        if (( count == expected_count )) && \
            (( ${#client_sessions[@]} == expected_count )); then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

function current_client_sessions {
    local root="$1"

    run_tmux "$root" list-clients -F '#{client_session}' 2>/dev/null | \
        LC_ALL=C sort || true
}

function client_fingerprint {
    local root="$1"

    run_tmux "$root" list-clients \
        -F '#{client_pid}|#{client_tty}|#{client_session}' 2>/dev/null | \
        LC_ALL=C sort
}

function one_server_snapshot {
    local root="$1"
    local server_kind="$2"
    local socket_name="default"
    local socket_path=""
    local panes=""
    local clients=""
    local pane_rc=0

    if [[ "$server_kind" == "runner" ]]; then
        socket_name="$RUNNER_SERVER_NAME"
        panes=$(run_tmux "$root" list-panes -a \
            -F '#{session_name}|#{session_id}|#{window_id}|#{pane_id}|#{pane_current_path}' \
            2>/dev/null) || pane_rc=$?
        clients=$(run_tmux "$root" list-clients \
            -F '#{client_pid}|#{client_tty}|#{client_session}' \
            2>/dev/null || true)
    else
        panes=$(run_default_tmux "$root" list-panes -a \
            -F '#{session_name}|#{session_id}|#{window_id}|#{pane_id}|#{pane_current_path}' \
            2>/dev/null) || pane_rc=$?
        clients=$(run_default_tmux "$root" list-clients \
            -F '#{client_pid}|#{client_tty}|#{client_session}' \
            2>/dev/null || true)
    fi
    socket_path="$root/tmux-$UID/$socket_name"
    if (( pane_rc != 0 )); then
        printf '%s|absent|socket=%s\n' "$server_kind" \
            "$([[ -S "$socket_path" ]] && printf present || printf absent)"
        return 0
    fi
    printf '%s|present|socket=%s\n' "$server_kind" \
        "$([[ -S "$socket_path" ]] && printf present || printf absent)"
    printf '%s|panes|%s\n' "$server_kind" \
        "$(printf '%s\n' "$panes" | LC_ALL=C sort)"
    printf '%s|clients|%s\n' "$server_kind" \
        "$(printf '%s\n' "$clients" | LC_ALL=C sort)"
}

function dual_server_snapshot {
    local root="$1"

    one_server_snapshot "$root" default
    one_server_snapshot "$root" runner
}

function monitor_dual_state_until_stop {
    local root="$1"
    local expected="$2"
    local stop_file="$3"
    local report_file="$4"
    local ready_file="$5"
    local actual=""
    local ready=0

    while true; do
        actual=$(dual_server_snapshot "$root")
        if [[ "$actual" != "$expected" ]]; then
            {
                printf 'Expected dual-server snapshot:\n%s\n' "$expected"
                printf 'Observed dual-server snapshot:\n%s\n' "$actual"
            } > "$report_file"
            if (( ! ready )); then
                printf 'ready\n' > "$ready_file"
            fi
            return 0
        fi
        if (( ! ready )); then
            printf 'ready\n' > "$ready_file"
            ready=1
        fi
        if [[ -e "$stop_file" ]]; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
}

function start_dual_state_monitor {
    local label="$1"
    local root="$2"
    local expected=""

    if [[ -n "$STATE_MONITOR_PID" ]]; then
        fail_test "a state monitor is already active"
    fi
    STATE_MONITOR_SEQUENCE=$((STATE_MONITOR_SEQUENCE + 1))
    STATE_MONITOR_STOP="$WORKSPACE/pty/$label-state-$STATE_MONITOR_SEQUENCE.stop"
    STATE_MONITOR_REPORT="$WORKSPACE/pty/$label-state-$STATE_MONITOR_SEQUENCE.report"
    STATE_MONITOR_READY="$WORKSPACE/pty/$label-state-$STATE_MONITOR_SEQUENCE.ready"
    rm -f -- "$STATE_MONITOR_STOP" "$STATE_MONITOR_READY"
    : > "$STATE_MONITOR_REPORT"
    expected=$(dual_server_snapshot "$root")
    monitor_dual_state_until_stop "$root" "$expected" \
        "$STATE_MONITOR_STOP" "$STATE_MONITOR_REPORT" \
        "$STATE_MONITOR_READY" &
    STATE_MONITOR_PID=$!
    record_manifest pid "$STATE_MONITOR_PID"
    if ! wait_for_file "$STATE_MONITOR_READY"; then
        fail_test "$label dual-server monitor did not become ready"
    fi
}

function monitor_state_until_stop {
    local root="$1"
    local expected_fingerprint="$2"
    local expected_clients="$3"
    local stop_file="$4"
    local report_file="$5"
    local ready_file="$6"
    local actual_fingerprint=""
    local actual_clients=""
    local fingerprint_rc=0
    local clients_rc=0
    local ready=0

    while true; do
        fingerprint_rc=0
        clients_rc=0
        actual_fingerprint=$(server_fingerprint "$root" 2>/dev/null) || \
            fingerprint_rc=$?
        actual_clients=$(client_fingerprint "$root") || clients_rc=$?
        if (( fingerprint_rc != 0 || clients_rc != 0 )); then
            {
                printf 'State query failed.\n'
                printf 'Fingerprint query exit: %d\n' "$fingerprint_rc"
                printf 'Client query exit: %d\n' "$clients_rc"
            } > "$report_file"
            if (( ! ready )); then
                printf 'ready\n' > "$ready_file"
            fi
            return 0
        fi
        if [[ "$actual_fingerprint" != "$expected_fingerprint" ]] || \
            [[ "$actual_clients" != "$expected_clients" ]]; then
            {
                printf 'Expected fingerprint:\n%s\n' "$expected_fingerprint"
                printf 'Observed fingerprint:\n%s\n' "$actual_fingerprint"
                printf 'Expected clients:\n%s\n' "$expected_clients"
                printf 'Observed clients:\n%s\n' "$actual_clients"
            } > "$report_file"
            if (( ! ready )); then
                printf 'ready\n' > "$ready_file"
            fi
            return 0
        fi
        if (( ! ready )); then
            printf 'ready\n' > "$ready_file"
            ready=1
        fi
        if [[ -e "$stop_file" ]]; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
}

function start_state_monitor {
    local label="$1"
    local root="$2"
    local expected_fingerprint=""
    local expected_clients=""

    if [[ -n "$STATE_MONITOR_PID" ]]; then
        fail_test "a state monitor is already active"
    fi
    STATE_MONITOR_SEQUENCE=$((STATE_MONITOR_SEQUENCE + 1))
    STATE_MONITOR_STOP="$WORKSPACE/pty/$label-state-$STATE_MONITOR_SEQUENCE.stop"
    STATE_MONITOR_REPORT="$WORKSPACE/pty/$label-state-$STATE_MONITOR_SEQUENCE.report"
    STATE_MONITOR_READY="$WORKSPACE/pty/$label-state-$STATE_MONITOR_SEQUENCE.ready"
    rm -f -- "$STATE_MONITOR_STOP" "$STATE_MONITOR_READY"
    : > "$STATE_MONITOR_REPORT"
    if ! expected_fingerprint=$(server_fingerprint "$root"); then
        fail_test "$label could not capture the initial server state"
    fi
    if ! expected_clients=$(client_fingerprint "$root"); then
        fail_test "$label could not capture the initial client state"
    fi
    monitor_state_until_stop "$root" "$expected_fingerprint" \
        "$expected_clients" "$STATE_MONITOR_STOP" "$STATE_MONITOR_REPORT" \
        "$STATE_MONITOR_READY" &
    STATE_MONITOR_PID=$!
    record_manifest pid "$STATE_MONITOR_PID"
    if ! wait_for_file "$STATE_MONITOR_READY"; then
        fail_test "$label state monitor did not become ready"
    fi
    if [[ -s "$STATE_MONITOR_REPORT" ]]; then
        stop_state_monitor "$label"
    fi
}

function stop_state_monitor {
    local label="$1"
    local monitor_pid="$STATE_MONITOR_PID"
    local report_file="$STATE_MONITOR_REPORT"

    if [[ -z "$monitor_pid" ]]; then
        fail_test "no state monitor is active"
    fi
    : > "$STATE_MONITOR_STOP"
    wait "$monitor_pid"
    STATE_MONITOR_PID=""
    STATE_MONITOR_STOP=""
    STATE_MONITOR_REPORT=""
    STATE_MONITOR_READY=""
    if [[ -s "$report_file" ]]; then
        printf 'State monitor report:\n' >&2
        sed -n '1,160p' "$report_file" >&2
        fail_test "$label changed tmux state while it was running"
    fi
}

function run_outside_success {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local runner="$5"
    local expected_session="$6"

    shift 6
    start_runner_outside "$label" "$root" "$home" "$xdg_home" \
        "$runner" "$@"
    if ! wait_for_client_session "$root" "$expected_session"; then
        fail_test "$label did not reach $expected_session"
    fi
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "$label failed"
}

function run_outside_failure {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local runner="$5"

    shift 5
    start_state_monitor "$label" "$root"
    start_runner_outside "$label" "$root" "$home" "$xdg_home" \
        "$runner" "$@"
    finish_current_pty
    stop_state_monitor "$label"
    assert_last_pty_failed_without_timeout "$label did not fail cleanly"
}

function run_outside_syntax_failure {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local runner="$5"

    shift 5
    run_outside_failure "$label" "$root" "$home" "$xdg_home" \
        "$runner" "$@"
    assert_not_contains "$LAST_TRANSCRIPT" "if-shell -F" \
        "$label reached the final entry seam"
}

function run_outside_create_syntax_failure {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local runner="$5"

    shift 5
    run_outside_failure "$label" "$root" "$home" "$xdg_home" \
        "$runner" "$@"
    assert_not_contains "$LAST_TRANSCRIPT" \
        "$TMUX_RUNNER_TRACE_PREFIX has-session" \
        "$label called has-session"
    assert_not_contains "$LAST_TRANSCRIPT" \
        "$TMUX_RUNNER_TRACE_PREFIX new-session" \
        "$label called new-session"
    assert_not_contains "$LAST_TRANSCRIPT" "if-shell -F" \
        "$label reached the final entry seam"
}

function run_concurrent_create {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local runner="$5"
    local session_name="$6"
    local directory="$7"
    local barrier_fifo="$WORKSPACE/pty/$label.barrier"
    local ready_one="$WORKSPACE/pty/$label-one.ready"
    local ready_two="$WORKSPACE/pty/$label-two.ready"
    local fifo_one="$WORKSPACE/pty/$label-one.fifo"
    local fifo_two="$WORKSPACE/pty/$label-two.fifo"
    local transcript_one="$WORKSPACE/pty/$label-one.typescript"
    local transcript_two="$WORKSPACE/pty/$label-two.typescript"
    local console_one="$WORKSPACE/pty/$label-one.console"
    local console_two="$WORKSPACE/pty/$label-two.console"
    local command_one=""
    local command_two=""
    local barrier_fd=""
    local fd_one=""
    local fd_two=""
    local pid_one=""
    local pid_two=""
    local rc_one=0
    local rc_two=0
    local recovery_trace=""
    local recheck_count=0
    local sync_bin="$WORKSPACE/pty/$label-bin"
    local sync_ready="$WORKSPACE/pty/$label-tmux-ready"
    local sync_tmux="$WORKSPACE/pty/$label-bin/tmux"
    local race_trace_prefix=""
    # Positional parameters are expanded by the child Bash process.
    # shellcheck disable=SC2016
    local wrapper='printf "ready\n" > "$1"; IFS= read -r < "$2"; shift 2; exec "$@"'

    race_trace_prefix="$sync_tmux -L $RUNNER_SERVER_NAME -f /dev/null"
    mkdir -p -- "$sync_bin" "$sync_ready"
    # shellcheck disable=SC2016
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -euo pipefail'
        printf '%s\n' 'tmux_args=("$@")'
        printf '%s\n' 'if [[ " $* " == *" new-session "* ]] && [[ " $* " == *" -s ${TMUX_RUNNER_TEST_RACE_TARGET} "* ]]; then'
        printf '%s\n' '    : > "${TMUX_RUNNER_TEST_RACE_READY}/$$"'
        printf '%s\n' '    deadline=$((SECONDS + 10))'
        printf '%s\n' '    while (( SECONDS <= deadline )); do'
        printf '%s\n' '        shopt -s nullglob'
        printf '%s\n' '        ready_files=("${TMUX_RUNNER_TEST_RACE_READY}"/*)'
        printf '%s\n' '        if (( ${#ready_files[@]} >= 2 )); then'
        printf '%s\n' '            break'
        printf '%s\n' '        fi'
        printf '%s\n' '        sleep 0.01'
        printf '%s\n' '    done'
        printf '%s\n' '    if (( ${#ready_files[@]} < 2 )); then'
        printf '%s\n' '        printf "tmux race barrier timed out\n" >&2'
        printf '%s\n' '        exit 99'
        printf '%s\n' '    fi'
        printf '%s\n' 'fi'
        printf '%s\n' 'exec "$TMUX_RUNNER_TEST_REAL_TMUX" "${tmux_args[@]}"'
    } > "$sync_tmux"
    chmod 0755 "$sync_tmux"

    mkfifo -- "$barrier_fifo" "$fifo_one" "$fifo_two"
    exec {barrier_fd}<>"$barrier_fifo"
    EXTRA_PTY_FDS+=("$barrier_fd")
    printf -v command_one '%q ' bash -c "$wrapper" concurrent-create \
        "$ready_one" "$barrier_fifo" env PATH="$sync_bin:$PATH" \
        TMUX_RUNNER_TEST_REAL_TMUX="$TMUX_PATH" \
        TMUX_RUNNER_TEST_RACE_TARGET="$session_name" \
        TMUX_RUNNER_TEST_RACE_READY="$sync_ready" bash -x "$runner" create \
        -s "$session_name" -c "$directory"
    command_one="${command_one% }"
    printf -v command_two '%q ' bash -c "$wrapper" concurrent-create \
        "$ready_two" "$barrier_fifo" env PATH="$sync_bin:$PATH" \
        TMUX_RUNNER_TEST_REAL_TMUX="$TMUX_PATH" \
        TMUX_RUNNER_TEST_RACE_TARGET="$session_name" \
        TMUX_RUNNER_TEST_RACE_READY="$sync_ready" bash -x "$runner" create \
        -s "$session_name" -c "$directory"
    command_two="${command_two% }"

    LAST_TRANSCRIPT="$transcript_one"
    LAST_CONSOLE="$console_one"
    setsid env -u TMUX HOME="$home" XDG_CONFIG_HOME="$xdg_home" \
        TMUX_TMPDIR="$root" SHELL=/bin/bash \
        timeout --foreground -k 2s "${PTY_TIMEOUT_SECONDS}s" \
        script -q -e -f -c "$command_one" "$transcript_one" \
        < "$fifo_one" > "$console_one" 2>&1 &
    pid_one=$!
    record_manifest pid "$pid_one"
    EXTRA_PTY_PIDS+=("$pid_one")
    exec {fd_one}>"$fifo_one"
    EXTRA_PTY_FDS+=("$fd_one")

    setsid env -u TMUX HOME="$home" XDG_CONFIG_HOME="$xdg_home" \
        TMUX_TMPDIR="$root" SHELL=/bin/bash \
        timeout --foreground -k 2s "${PTY_TIMEOUT_SECONDS}s" \
        script -q -e -f -c "$command_two" "$transcript_two" \
        < "$fifo_two" > "$console_two" 2>&1 &
    pid_two=$!
    record_manifest pid "$pid_two"
    EXTRA_PTY_PIDS+=("$pid_two")
    exec {fd_two}>"$fifo_two"
    EXTRA_PTY_FDS+=("$fd_two")

    if ! wait_for_file "$ready_one" || ! wait_for_file "$ready_two"; then
        fail_test "$label runners did not reach the release barrier"
    fi
    printf '\n\n' >&"$barrier_fd"
    exec {barrier_fd}>&-
    if ! wait_for_client_count "$root" "$session_name" 2; then
        fail_test "$label did not attach both concurrent clients"
    fi
    run_tmux "$root" detach-client -s "=$session_name"
    exec {fd_one}>&-
    exec {fd_two}>&-
    wait "$pid_one" || rc_one=$?
    wait "$pid_two" || rc_two=$?
    EXTRA_PTY_PIDS=()
    EXTRA_PTY_FDS=()

    assert_equal "0" "$rc_one" "$label first runner failed"
    assert_equal "0" "$rc_two" "$label second runner failed"
    assert_session_entry_trace_with_prefix "$transcript_one" "$root" \
        "$session_name" "$race_trace_prefix" \
        "$label first runner did not attach exactly"
    assert_session_entry_trace_with_prefix "$transcript_two" "$root" \
        "$session_name" "$race_trace_prefix" \
        "$label second runner did not attach exactly"
    assert_contains "$transcript_one" \
        "$race_trace_prefix new-session -d -s $session_name" \
        "$label first runner did not attempt creation"
    assert_contains "$transcript_two" \
        "$race_trace_prefix new-session -d -s $session_name" \
        "$label second runner did not attempt creation"
    if grep -F -- '+ create_rc=1' "$transcript_one" >/dev/null; then
        recovery_trace="$transcript_one"
    elif grep -F -- '+ create_rc=1' "$transcript_two" >/dev/null; then
        recovery_trace="$transcript_two"
    else
        fail_test "$label did not exercise duplicate-create recovery"
    fi
    recheck_count=$(grep -Fc -- \
        "+ run_tmux_command has-session -t =$session_name" \
        "$recovery_trace") || true
    if (( recheck_count < 2 )); then
        fail_test "$label loser did not recheck the exact session"
    fi
}

function run_concurrent_auto_create {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local runner="$5"
    local path_one="$6"
    local path_two="$7"
    local barrier_fifo="$WORKSPACE/pty/$label.barrier"
    local ready_one="$WORKSPACE/pty/$label-one.ready"
    local ready_two="$WORKSPACE/pty/$label-two.ready"
    local fifo_one="$WORKSPACE/pty/$label-one.fifo"
    local fifo_two="$WORKSPACE/pty/$label-two.fifo"
    local transcript_one="$WORKSPACE/pty/$label-one.typescript"
    local transcript_two="$WORKSPACE/pty/$label-two.typescript"
    local console_one="$WORKSPACE/pty/$label-one.console"
    local console_two="$WORKSPACE/pty/$label-two.console"
    local command_one=""
    local command_two=""
    local barrier_fd=""
    local fd_one=""
    local fd_two=""
    local pid_one=""
    local pid_two=""
    local rc_one=0
    local rc_two=0
    local target_one=""
    local target_two=""
    local clients=""
    local deadline=0
    local base_name=""
    local short_hostname=""
    local sync_bin="$WORKSPACE/pty/$label-bin"
    local sync_ready="$WORKSPACE/pty/$label-tmux-ready"
    local sync_tmux="$WORKSPACE/pty/$label-bin/tmux"
    local race_trace_prefix=""
    # Positional parameters are expanded by the child Bash process.
    # shellcheck disable=SC2016
    local wrapper='printf "ready\n" > "$1"; IFS= read -r < "$2"; shift 2; exec "$@"'

    short_hostname=$(hostname -s)
    short_hostname="${short_hostname//./_}"
    short_hostname="${short_hostname//:/_}"
    base_name="${path_one##*/}-$short_hostname"
    race_trace_prefix="$sync_tmux -L $RUNNER_SERVER_NAME -f /dev/null"
    mkdir -p -- "$sync_bin" "$sync_ready"
    # shellcheck disable=SC2016
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -euo pipefail'
        printf '%s\n' 'tmux_args=("$@")'
        printf '%s\n' 'if [[ " $* " == *" new-session "* ]] && [[ " $* " == *" -s ${TMUX_RUNNER_TEST_RACE_TARGET} "* ]]; then'
        printf '%s\n' '    : > "${TMUX_RUNNER_TEST_RACE_READY}/$$"'
        printf '%s\n' '    deadline=$((SECONDS + 10))'
        printf '%s\n' '    while (( SECONDS <= deadline )); do'
        printf '%s\n' '        shopt -s nullglob'
        printf '%s\n' '        ready_files=("${TMUX_RUNNER_TEST_RACE_READY}"/*)'
        printf '%s\n' '        if (( ${#ready_files[@]} >= 2 )); then'
        printf '%s\n' '            break'
        printf '%s\n' '        fi'
        printf '%s\n' '        sleep 0.01'
        printf '%s\n' '    done'
        printf '%s\n' '    if (( ${#ready_files[@]} < 2 )); then'
        printf '%s\n' '        printf "tmux race barrier timed out\n" >&2'
        printf '%s\n' '        exit 99'
        printf '%s\n' '    fi'
        printf '%s\n' 'fi'
        printf '%s\n' 'exec "$TMUX_RUNNER_TEST_REAL_TMUX" "${tmux_args[@]}"'
    } > "$sync_tmux"
    chmod 0755 "$sync_tmux"

    mkfifo -- "$barrier_fifo" "$fifo_one" "$fifo_two"
    exec {barrier_fd}<>"$barrier_fifo"
    EXTRA_PTY_FDS+=("$barrier_fd")
    printf -v command_one '%q ' bash -c "$wrapper" concurrent-auto \
        "$ready_one" "$barrier_fifo" env \
        PATH="$sync_bin:$PATH" TMUX_RUNNER_TEST_REAL_TMUX="$TMUX_PATH" \
        TMUX_RUNNER_TEST_RACE_TARGET="$base_name" \
        TMUX_RUNNER_TEST_RACE_READY="$sync_ready" \
        bash -x "$runner" create -c "$path_one"
    command_one="${command_one% }"
    printf -v command_two '%q ' bash -c "$wrapper" concurrent-auto \
        "$ready_two" "$barrier_fifo" env \
        PATH="$sync_bin:$PATH" TMUX_RUNNER_TEST_REAL_TMUX="$TMUX_PATH" \
        TMUX_RUNNER_TEST_RACE_TARGET="$base_name" \
        TMUX_RUNNER_TEST_RACE_READY="$sync_ready" \
        bash -x "$runner" create -c "$path_two"
    command_two="${command_two% }"

    setsid env -u TMUX HOME="$home" XDG_CONFIG_HOME="$xdg_home" \
        TMUX_TMPDIR="$root" SHELL=/bin/bash \
        timeout --foreground -k 2s "${PTY_TIMEOUT_SECONDS}s" \
        script -q -e -f -c "$command_one" "$transcript_one" \
        < "$fifo_one" > "$console_one" 2>&1 &
    pid_one=$!
    record_manifest pid "$pid_one"
    EXTRA_PTY_PIDS+=("$pid_one")
    exec {fd_one}>"$fifo_one"
    EXTRA_PTY_FDS+=("$fd_one")

    setsid env -u TMUX HOME="$home" XDG_CONFIG_HOME="$xdg_home" \
        TMUX_TMPDIR="$root" SHELL=/bin/bash \
        timeout --foreground -k 2s "${PTY_TIMEOUT_SECONDS}s" \
        script -q -e -f -c "$command_two" "$transcript_two" \
        < "$fifo_two" > "$console_two" 2>&1 &
    pid_two=$!
    record_manifest pid "$pid_two"
    EXTRA_PTY_PIDS+=("$pid_two")
    exec {fd_two}>"$fifo_two"
    EXTRA_PTY_FDS+=("$fd_two")

    if ! wait_for_file "$ready_one" || ! wait_for_file "$ready_two"; then
        fail_test "$label runners did not reach the release barrier"
    fi
    printf '\n\n' >&"$barrier_fd"
    exec {barrier_fd}>&-

    deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))
    while (( SECONDS <= deadline )); do
        clients=$(current_client_sessions "$root")
        if (( $(grep -c . <<< "$clients") == 2 )); then
            break
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    if (( $(grep -c . <<< "$clients") != 2 )); then
        fail_test "$label did not attach both concurrent clients"
    fi

    target_one=$(session_name_for_path "$root" "$path_one")
    target_two=$(session_name_for_path "$root" "$path_two")
    if [[ -z "$target_one" ]] || [[ "$target_one" == *$'\n'* ]]; then
        fail_test "$label first path did not have exactly one marked session"
    fi
    if [[ -z "$target_two" ]] || [[ "$target_two" == *$'\n'* ]]; then
        fail_test "$label second path did not have exactly one marked session"
    fi
    assert_not_equal "$target_one" "$target_two" \
        "$label reused one session for different paths"
    assert_session_entry_trace_with_prefix "$transcript_one" "$root" \
        "$target_one" "$race_trace_prefix" \
        "$label first client entered the wrong path"
    assert_session_entry_trace_with_prefix "$transcript_two" "$root" \
        "$target_two" "$race_trace_prefix" \
        "$label second client entered the wrong path"

    assert_contains "$transcript_one" \
        "$race_trace_prefix new-session -d -s $base_name" \
        "$label first runner did not race for the base name"
    assert_contains "$transcript_two" \
        "$race_trace_prefix new-session -d -s $base_name" \
        "$label second runner did not race for the base name"
    if grep -F -- '+ create_rc=1' "$transcript_one" >/dev/null; then
        if (( $(grep -Fc -- '+ load_managed_sessions' "$transcript_one") < 3 )); then
            fail_test "$label first race loser did not reload marked sessions"
        fi
    elif grep -F -- '+ create_rc=1' "$transcript_two" >/dev/null; then
        if (( $(grep -Fc -- '+ load_managed_sessions' "$transcript_two") < 3 )); then
            fail_test "$label second race loser did not reload marked sessions"
        fi
    else
        fail_test "$label did not exercise duplicate-create recovery"
    fi

    run_tmux "$root" detach-client -s "=$target_one"
    run_tmux "$root" detach-client -s "=$target_two"
    exec {fd_one}>&-
    exec {fd_two}>&-
    wait "$pid_one" || rc_one=$?
    wait "$pid_two" || rc_two=$?
    EXTRA_PTY_PIDS=()
    EXTRA_PTY_FDS=()
    assert_equal "0" "$rc_one" "$label first runner failed"
    assert_equal "0" "$rc_two" "$label second runner failed"
}

function start_source_client {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local source_session="$5"
    local config_file="$xdg_home/tmux-runner/tmux.conf"

    if [[ ! -e "$config_file" ]]; then
        config_file="/dev/null"
    fi

    start_pty_command "$label-client" "$root" "$home" "$xdg_home" \
        tmux -L "$RUNNER_SERVER_NAME" -f "$config_file" \
        attach-session -t "=$source_session"
    if ! wait_for_client_session "$root" "$source_session"; then
        fail_test "$label client did not attach to $source_session"
    fi
}

function start_default_source_client {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local source_session="$5"

    start_pty_command "$label-client" "$root" "$home" "$xdg_home" \
        tmux -f /dev/null attach-session -t "=$source_session"
    if ! wait_for_default_client_session "$root" "$source_session"; then
        fail_test "$label client did not attach to default session $source_session"
    fi
}

function invoke_runner_inside {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local source_session="$5"
    local runner="$6"
    local runner_command=""
    local shell_command=""

    shift 6
    LAST_INSIDE_TRACE="$WORKSPACE/pty/$label.inside-trace"
    LAST_INSIDE_STATUS="$WORKSPACE/pty/$label.inside-status"
    printf -v runner_command '%q ' env HOME="$home" \
        XDG_CONFIG_HOME="$xdg_home" TMUX_TMPDIR="$root" \
        bash -x "$runner" "$@"
    runner_command="${runner_command% }"
    printf -v shell_command \
        "set -o pipefail; %s 2>&1 | tee %q; runner_rc=\${PIPESTATUS[0]}; printf \"%%s\\\\n\" \"\$runner_rc\" > %q" \
        "$runner_command" "$LAST_INSIDE_TRACE" "$LAST_INSIDE_STATUS"

    run_tmux "$root" send-keys -t "$source_session:0.0" -l -- "$shell_command"
    run_tmux "$root" send-keys -t "$source_session:0.0" C-m
}

function invoke_runner_inside_default {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local source_session="$5"
    local runner="$6"
    local runner_command=""
    local shell_command=""

    shift 6
    LAST_INSIDE_TRACE="$WORKSPACE/pty/$label.inside-trace"
    LAST_INSIDE_STATUS="$WORKSPACE/pty/$label.inside-status"
    printf -v runner_command '%q ' env HOME="$home" \
        XDG_CONFIG_HOME="$xdg_home" TMUX_TMPDIR="$root" \
        bash -x "$runner" "$@"
    runner_command="${runner_command% }"
    printf -v shell_command \
        "set -o pipefail; %s 2>&1 | tee %q; runner_rc=\${PIPESTATUS[0]}; printf \"%%s\\\\n\" \"\$runner_rc\" > %q" \
        "$runner_command" "$LAST_INSIDE_TRACE" "$LAST_INSIDE_STATUS"

    run_default_tmux "$root" send-keys -t "$source_session:0.0" \
        -l -- "$shell_command"
    run_default_tmux "$root" send-keys -t "$source_session:0.0" C-m
}

function inside_runner_status {
    local status=""

    status=$(<"$LAST_INSIDE_STATUS")
    printf '%s\n' "$status"
}

function run_inside_success {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local source_session="$5"
    local expected_session="$6"
    local runner="$7"
    local status=""

    shift 7
    start_source_client "$label" "$root" "$home" "$xdg_home" \
        "$source_session"
    invoke_runner_inside "$label" "$root" "$home" "$xdg_home" \
        "$source_session" "$runner" "$@"
    if ! wait_for_client_session "$root" "$expected_session"; then
        fail_test "$label did not switch to $expected_session"
    fi
    if ! wait_for_file "$LAST_INSIDE_STATUS"; then
        fail_test "$label did not record its inside status"
    fi
    status=$(inside_runner_status)
    assert_equal "0" "$status" "$label returned a nonzero inside status"
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "$label source client failed"
}

function run_inside_failure {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local source_session="$5"
    local runner="$6"
    local status=""
    local clients=""

    shift 6
    start_source_client "$label" "$root" "$home" "$xdg_home" \
        "$source_session"
    start_state_monitor "$label" "$root"
    invoke_runner_inside "$label" "$root" "$home" "$xdg_home" \
        "$source_session" "$runner" "$@"
    if ! wait_for_file "$LAST_INSIDE_STATUS"; then
        fail_test "$label did not record its inside failure"
    fi
    status=$(inside_runner_status)
    assert_not_equal "0" "$status" "$label unexpectedly succeeded inside"
    stop_state_monitor "$label"
    clients=$(current_client_sessions "$root")
    assert_equal "$source_session" "$clients" \
        "$label moved the client after an invalid command"
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "$label source client failed"
}

function run_inside_syntax_failure {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local source_session="$5"
    local runner="$6"

    shift 6
    run_inside_failure "$label" "$root" "$home" "$xdg_home" \
        "$source_session" "$runner" "$@"
    assert_not_contains "$LAST_INSIDE_TRACE" "if-shell -F" \
        "$label reached the final entry seam"
}

function assert_session_set {
    local root="$1"
    local message="$2"
    local actual=""
    local expected=""

    shift 2
    actual=$(session_names "$root")
    expected=$(printf '%s\n' "$@" | LC_ALL=C sort)
    assert_equal "$expected" "$actual" "$message"
}

function assert_reply_set {
    local message="$1"
    local actual=""
    local expected=""

    shift
    actual=$(printf '%s\n' "${COMPREPLY[@]}" | LC_ALL=C sort)
    expected=$(printf '%s\n' "$@" | LC_ALL=C sort)
    assert_equal "$expected" "$actual" "$message"
}

function selection_number {
    local file="$1"
    local session_name="$2"

    awk -v prefix="$session_name:" \
        '$1 ~ /^[0-9]+$/ && index($2, prefix) == 1 { print $1; exit }' \
        "$file" | tr -d '\r'
}

function repository_selection_number {
    local file="$1"
    local repository_path="$2"

    tr -d '\r' < "$file" | awk -v path="$repository_path" \
        '$1 ~ /^[0-9]+$/ && index($0, "  " path) > 0 { print $1; exit }'
}

function repository_rows {
    local file="$1"

    tr -d '\r' < "$file" | awk '$1 ~ /^[0-9]+$/ { print }'
}

function assert_repository_row_count {
    local file="$1"
    local repository_path="$2"
    local expected_count="$3"
    local count=0

    count=$(repository_rows "$file" | \
        awk -v path="$repository_path" \
            'index($0, "  " path) > 0 { count++ } END { print count + 0 }')
    assert_equal "$expected_count" "$count" \
        "repository row count is wrong for $repository_path"
}

function run_repo_selection_success {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local expected_session="$5"
    local repository_path="$6"
    local number=""

    start_runner_outside "$label" "$root" "$home" "$xdg_home" \
        "$RUNNER" repo
    if ! wait_for_transcript_text "Select repository:"; then
        fail_test "$label did not display the repository prompt"
    fi
    number=$(repository_selection_number "$LAST_TRANSCRIPT" "$repository_path")
    if [[ -z "$number" ]]; then
        fail_test "$label did not display the selected repository"
    fi
    send_current_input "$number\n"
    if ! wait_for_client_session "$root" "$expected_session"; then
        fail_test "$label did not reach $expected_session"
    fi
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "$label failed"
    assert_session_entry_trace "$LAST_TRANSCRIPT" "$root" \
        "$expected_session" "$label did not target the selected session ID"
}

function run_concurrent_repo_selection {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local repository_path="$5"
    local expected_session="$6"
    local fifo_one="$WORKSPACE/pty/$label-one.fifo"
    local fifo_two="$WORKSPACE/pty/$label-two.fifo"
    local transcript_one="$WORKSPACE/pty/$label-one.typescript"
    local transcript_two="$WORKSPACE/pty/$label-two.typescript"
    local console_one="$WORKSPACE/pty/$label-one.console"
    local console_two="$WORKSPACE/pty/$label-two.console"
    local command_string=""
    local fd_one=""
    local fd_two=""
    local pid_one=""
    local pid_two=""
    local number_one=""
    local number_two=""
    local rc_one=0
    local rc_two=0

    mkfifo -- "$fifo_one" "$fifo_two"
    printf -v command_string '%q ' bash -x "$RUNNER" repo
    command_string="${command_string% }"

    setsid env -u TMUX HOME="$home" XDG_CONFIG_HOME="$xdg_home" \
        TMUX_TMPDIR="$root" SHELL=/bin/bash \
        timeout --foreground -k 2s "${PTY_TIMEOUT_SECONDS}s" \
        script -q -e -f -c "$command_string" "$transcript_one" \
        < "$fifo_one" > "$console_one" 2>&1 &
    pid_one=$!
    record_manifest pid "$pid_one"
    EXTRA_PTY_PIDS+=("$pid_one")
    exec {fd_one}>"$fifo_one"
    EXTRA_PTY_FDS+=("$fd_one")

    setsid env -u TMUX HOME="$home" XDG_CONFIG_HOME="$xdg_home" \
        TMUX_TMPDIR="$root" SHELL=/bin/bash \
        timeout --foreground -k 2s "${PTY_TIMEOUT_SECONDS}s" \
        script -q -e -f -c "$command_string" "$transcript_two" \
        < "$fifo_two" > "$console_two" 2>&1 &
    pid_two=$!
    record_manifest pid "$pid_two"
    EXTRA_PTY_PIDS+=("$pid_two")
    exec {fd_two}>"$fifo_two"
    EXTRA_PTY_FDS+=("$fd_two")

    if ! wait_for_file_text "$transcript_one" "Select repository:" || \
        ! wait_for_file_text "$transcript_two" "Select repository:"; then
        fail_test "$label selectors did not display both prompts"
    fi
    number_one=$(repository_selection_number "$transcript_one" \
        "$repository_path")
    number_two=$(repository_selection_number "$transcript_two" \
        "$repository_path")
    if [[ -z "$number_one" ]] || [[ -z "$number_two" ]]; then
        fail_test "$label selectors did not display the repository"
    fi
    printf '%s\n' "$number_one" >&"$fd_one"
    printf '%s\n' "$number_two" >&"$fd_two"
    if ! wait_for_client_count "$root" "$expected_session" 2; then
        fail_test "$label did not attach both selectors"
    fi
    run_tmux "$root" detach-client -s "=$expected_session"
    exec {fd_one}>&-
    exec {fd_two}>&-
    wait "$pid_one" || rc_one=$?
    wait "$pid_two" || rc_two=$?
    EXTRA_PTY_PIDS=()
    EXTRA_PTY_FDS=()
    assert_equal "0" "$rc_one" "$label first selector failed"
    assert_equal "0" "$rc_two" "$label second selector failed"
    assert_equal "1" \
        "$(session_name_for_path "$root" "$repository_path" | grep -c .)" \
        "$label created more than one session for one repository"
}

function assert_rows_visible {
    local file="$1"
    local rows="$2"
    local row=""

    while IFS= read -r row; do
        if [[ -n "$row" ]]; then
            assert_contains "$file" "$row" "a complete tmux ls row is missing"
        fi
    done <<< "$rows"
}

function runner_state_directory_for {
    local state_home="$1"

    printf '%s/tmux-runner\n' "$state_home"
}

function runner_socket_path_for_root {
    local root="$1"

    printf '%s/tmux-%s/%s\n' "$root" "$UID" "$RUNNER_SERVER_NAME"
}

function encode_state_field {
    local value="$1"

    value="${value//%/%25}"
    value="${value//$'\r'/%0D}"
    value="${value//$'\t'/%09}"
    value="${value//$'\n'/%0A}"
    printf '%s\n' "$value"
}

function state_snapshot {
    local state_directory="$1"
    local path=""
    local relative_path=""
    local mode=""
    local digest=""

    if [[ ! -d "$state_directory" ]]; then
        printf '%s\n' absent
        return 0
    fi
    printf 'directory|%s\n' "$(stat -c '%a' "$state_directory")"
    while IFS= read -r -d '' path; do
        relative_path="${path#"$state_directory"/}"
        mode=$(stat -c '%a' "$path")
        digest=$(sha256sum "$path")
        digest="${digest%% *}"
        printf '%s|%s|%s\n' "$relative_path" "$mode" "$digest"
    done < <(
        find "$state_directory" -mindepth 1 -maxdepth 1 -type f \
            -print0 | LC_ALL=C sort -z
    )
}

function state_record_values {
    local record_type="$1"
    local state_file="$2"

    if [[ ! -f "$state_file" ]]; then
        return 0
    fi
    awk -F '\t' -v record_type="$record_type" '
        $1 == record_type && record_type == "session" && NF == 4 {
            print $4
        }
        $1 == record_type && record_type == "recent" && NF == 4 {
            print $4
        }
    ' "$state_file"
}

function state_session_values_for_server {
    local state_file="$1"
    local server_identity="$2"
    local encoded_server=""

    if [[ ! -f "$state_file" ]]; then
        return 0
    fi
    encoded_server=$(encode_state_field "$server_identity")
    awk -F '\t' -v encoded_server="$encoded_server" '
        $1 == "session" && NF == 4 && $3 == encoded_server { print $4 }
    ' "$state_file"
}

function state_recent_kind_for_path {
    local state_file="$1"
    local canonical_path="$2"
    local encoded_path=""

    if [[ ! -f "$state_file" ]]; then
        return 0
    fi
    encoded_path=$(encode_state_field "$canonical_path")
    awk -F '\t' -v encoded_path="$encoded_path" '
        $1 == "recent" && NF == 4 && $4 == encoded_path { print $3 }
    ' "$state_file"
}

function validate_main_state_record {
    local state_file="$1"

    [[ -f "$state_file" ]] || return 0
    [[ "$(stat -c '%a' "$state_file")" == "600" ]] || return 1
    awk -F '\t' '
        $1 == "version" && NF == 2 && $2 == "2" {
            versions++
            next
        }
        $1 == "sequence" && NF == 2 && $2 ~ /^[0-9]+$/ {
            sequences++
            next
        }
        $1 == "session" && NF == 4 && $2 ~ /^[0-9]+$/ &&
            length($3) > 0 && length($4) > 0 {
            next
        }
        $1 == "recent" && NF == 4 && $2 ~ /^[0-9]+$/ &&
            ($3 == "git" || $3 == "plain") && length($4) > 0 {
            next
        }
        {
            bad = 1
        }
        END {
            exit !(versions == 1 && sequences == 1 && bad == 0)
        }
    ' "$state_file"
}

function assert_state_modes {
    local state_directory="$1"
    local path=""

    assert_equal "700" "$(stat -c '%a' "$state_directory")" \
        "state directory mode is wrong"
    while IFS= read -r -d '' path; do
        assert_equal "600" "$(stat -c '%a' "$path")" \
            "state record mode is wrong: $path"
    done < <(find "$state_directory" -maxdepth 1 -type f -print0)
}

function assert_no_state_transactions {
    local state_directory="$1"
    local debris=""

    debris=$(find "$state_directory" -maxdepth 1 -type f \
        \( -name 'pending.*' -o -name 'ack.*' \
        -o -name '.pending.*' -o -name '.ack.*' \
        -o -name '.state.tmp.*' \) -print)
    assert_equal "" "$debris" "state transaction files remain"
}

function wait_for_state_value {
    local state_file="$1"
    local record_type="$2"
    local encoded_value="$3"
    local deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))

    while (( SECONDS <= deadline )); do
        if [[ -f "$state_file" ]] && awk -F '\t' \
            -v record_type="$record_type" -v value="$encoded_value" '
                $1 == record_type && record_type == "session" &&
                    NF == 4 && $4 == value { found = 1 }
                $1 == record_type && record_type == "recent" &&
                    NF == 4 && $4 == value { found = 1 }
                END { exit !found }
            ' "$state_file"; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

function wait_for_state_row_count {
    local state_file="$1"
    local record_type="$2"
    local expected_count="$3"
    local count=0
    local deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))

    while (( SECONDS <= deadline )); do
        if [[ -f "$state_file" ]]; then
            count=$(awk -F '\t' -v record_type="$record_type" '
                $1 == record_type && record_type == "session" && NF == 4 {
                    count++
                }
                $1 == record_type && record_type == "recent" && NF == 4 {
                    count++
                }
                END { print count + 0 }
            ' "$state_file")
            if (( count == expected_count )); then
                return 0
            fi
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

function wait_for_first_state_value {
    local state_file="$1"
    local record_type="$2"
    local encoded_value="$3"
    local first_value=""
    local deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))

    while (( SECONDS <= deadline )); do
        first_value=$(state_record_values "$record_type" "$state_file" | \
            sed -n '1p')
        if [[ "$first_value" == "$encoded_value" ]]; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

function wait_for_no_state_transactions {
    local state_directory="$1"
    local debris=""
    local deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))

    while (( SECONDS <= deadline )); do
        debris=$(find "$state_directory" -maxdepth 1 -type f \
            \( -name 'pending.*' -o -name 'ack.*' \
            -o -name '.pending.*' -o -name '.ack.*' \
            -o -name '.state.tmp.*' \) -print)
        if [[ -z "$debris" ]]; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

function wait_for_pending_file {
    local state_directory="$1"
    local deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))
    local nullglob_was_set=0
    local -a pending_files=()

    if shopt -q nullglob; then
        nullglob_was_set=1
    fi
    shopt -s nullglob
    while (( SECONDS <= deadline )); do
        pending_files=("$state_directory"/pending.*)
        if (( ${#pending_files[@]} == 1 )); then
            LAST_PENDING_FILE="${pending_files[0]}"
            if (( ! nullglob_was_set )); then
                shopt -u nullglob
            fi
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    if (( ! nullglob_was_set )); then
        shopt -u nullglob
    fi
    return 1
}

function wait_for_pending_ack {
    local pending_file="$1"
    local state_directory="${pending_file%/*}"
    local transaction_id="${pending_file##*/pending.}"
    local ack_file="$state_directory/ack.$transaction_id"
    local deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))

    while (( SECONDS <= deadline )); do
        if [[ -f "$ack_file" ]] && [[ ! -L "$ack_file" ]] && \
            [[ "$(stat -c '%a' "$ack_file")" == "600" ]] && \
            grep -Fx -- $'version\t2' "$ack_file" >/dev/null; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

function assert_versioned_transaction_record {
    local record_file="$1"
    local label="$2"

    if [[ ! -f "$record_file" ]] || [[ -L "$record_file" ]]; then
        fail_test "$label is not a regular state record"
    fi
    assert_equal "600" "$(stat -c '%a' "$record_file")" \
        "$label mode is wrong"
    if ! grep -Fx -- $'version\t2' "$record_file" >/dev/null; then
        fail_test "$label is not a complete versioned state record"
    fi
}

function acknowledged_record_for_pending {
    local pending_file="$1"
    local state_directory="${pending_file%/*}"
    local transaction_id="${pending_file##*/pending.}"

    printf '%s/ack.%s\n' "$state_directory" "$transaction_id"
}

function crash_current_pty_after_acknowledgment {
    local label="$1"
    local pending_file="$2"
    local ack_file=""
    local ready_file="$WORKSPACE/pty/$label-ack-crash.ready"
    local runner_pid="$CURRENT_PTY_PID"
    local watcher_pid=""
    local deadline=0
    local rc=0

    if [[ -z "$runner_pid" ]]; then
        fail_test "$label has no PTY process to terminate"
    fi
    ack_file=$(acknowledged_record_for_pending "$pending_file")
    rm -f -- "$ready_file"
    (
        deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))
        while (( SECONDS <= deadline )); do
            if [[ -f "$ack_file" ]] && [[ ! -L "$ack_file" ]]; then
                kill -TERM -- "-$runner_pid" 2>/dev/null || \
                    kill -TERM "$runner_pid" 2>/dev/null || true
                printf 'ready\n' > "$ready_file"
                exit 0
            fi
            sleep 0.001
        done
        printf 'timeout\n' > "$ready_file"
        exit 1
    ) &
    watcher_pid=$!
    record_manifest pid "$watcher_pid"
    release_attach_gate
    if ! wait_for_file "$ready_file"; then
        fail_test "$label acknowledgment watcher did not report"
    fi
    if ! wait "$watcher_pid"; then
        fail_test "$label did not observe an acknowledgment"
    fi
    wait "$runner_pid" || rc=$?
    close_current_pty_input
    CURRENT_PTY_PID=""
    LAST_PTY_RC=$rc
    ATTACH_GATE_READY=""
    ATTACH_GATE_RELEASE=""
    assert_versioned_transaction_record "$pending_file" \
        "$label pending transaction"
    assert_versioned_transaction_record "$ack_file" \
        "$label acknowledgment"
}

function recent_selection_number {
    local file="$1"
    local canonical_path="$2"
    local encoded_path=""

    encoded_path=$(encode_state_field "$canonical_path")
    tr -d '\r' < "$file" | awk -v target="$encoded_path" '
        $1 ~ /^[0-9]+$/ && index($0, " ") > 0 {
            value = substr($0, index($0, " ") + 1)
            if (value == target) {
                print $1
                exit
            }
        }
    '
}

function recent_display_paths {
    local file="$1"

    tr -d '\r' < "$file" | awk '
        $1 ~ /^[0-9]+$/ && NF >= 2 && index($0, " ") > 0 {
            print substr($0, index($0, " ") + 1)
        }
    '
}

function run_recent_selection_success {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local runner="$5"
    local expected_session="$6"
    local canonical_path="$7"
    local number=""

    start_runner_outside "$label" "$root" "$home" "$xdg_home" \
        "$runner" recent
    if ! wait_for_transcript_text "Select recent destination:"; then
        fail_test "$label did not display the recent prompt"
    fi
    number=$(recent_selection_number "$LAST_TRANSCRIPT" "$canonical_path")
    if [[ -z "$number" ]]; then
        fail_test "$label did not display the requested recent path"
    fi
    send_current_input "$number\n"
    if ! wait_for_client_session "$root" "$expected_session"; then
        fail_test "$label did not reach $expected_session"
    fi
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "$label failed"
    assert_session_entry_trace "$LAST_TRANSCRIPT" "$root" \
        "$expected_session" "$label did not target the recent session ID"
}

function run_list_selection_success {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local runner="$5"
    local expected_session="$6"
    local number=""

    start_runner_outside "$label" "$root" "$home" "$xdg_home" \
        "$runner" ls
    if ! wait_for_transcript_text "Select session:"; then
        fail_test "$label did not display the session prompt"
    fi
    number=$(selection_number "$LAST_TRANSCRIPT" "$expected_session")
    if [[ -z "$number" ]]; then
        fail_test "$label did not display $expected_session"
    fi
    send_current_input "$number\n"
    if ! wait_for_client_session "$root" "$expected_session"; then
        fail_test "$label did not reach $expected_session"
    fi
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "$label failed"
    assert_session_entry_trace "$LAST_TRANSCRIPT" "$root" \
        "$expected_session" "$label did not target the listed session ID"
}

function monitor_state_records_until_stop {
    local root="$1"
    local home="$2"
    local xdg_home="$3"
    local state_home="$4"
    local state_file="$5"
    local stop_file="$6"
    local report_file="$7"
    local ready_file="$8"
    local reader_output=""
    local ready=0

    while true; do
        if [[ -f "$state_file" ]] && \
            ! validate_main_state_record "$state_file"; then
            printf 'Observed an incomplete main state record.\n' \
                > "$report_file"
            if (( ! ready )); then
                printf 'ready\n' > "$ready_file"
            fi
            return 0
        fi
        reader_output=""
        reader_output=$(printf 'not-a-number\n' | \
            env -u TMUX HOME="$home" XDG_CONFIG_HOME="$xdg_home" \
                XDG_STATE_HOME="$state_home" TMUX_TMPDIR="$root" \
                bash "$RUNNER" recent 2>&1) || true
        if [[ "$reader_output" == *"state version is incompatible"* ]] || \
            [[ "$reader_output" == *"state lock timed out"* ]]; then
            printf 'Concurrent reader failed: %s\n' "$reader_output" \
                > "$report_file"
            if (( ! ready )); then
                printf 'ready\n' > "$ready_file"
            fi
            return 0
        fi
        if (( ! ready )); then
            printf 'ready\n' > "$ready_file"
            ready=1
        fi
        if [[ -e "$stop_file" ]]; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
}

function start_state_record_monitor {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local state_home="$5"
    local state_file=""

    state_file="$(runner_state_directory_for "$state_home")/state"
    if [[ -n "$STATE_RECORD_MONITOR_PID" ]]; then
        fail_test "a state record monitor is already active"
    fi
    STATE_RECORD_MONITOR_STOP="$WORKSPACE/pty/$label-record.stop"
    STATE_RECORD_MONITOR_REPORT="$WORKSPACE/pty/$label-record.report"
    STATE_RECORD_MONITOR_READY="$WORKSPACE/pty/$label-record.ready"
    rm -f -- "$STATE_RECORD_MONITOR_STOP" "$STATE_RECORD_MONITOR_READY"
    : > "$STATE_RECORD_MONITOR_REPORT"
    monitor_state_records_until_stop "$root" "$home" "$xdg_home" \
        "$state_home" "$state_file" "$STATE_RECORD_MONITOR_STOP" \
        "$STATE_RECORD_MONITOR_REPORT" "$STATE_RECORD_MONITOR_READY" &
    STATE_RECORD_MONITOR_PID=$!
    record_manifest pid "$STATE_RECORD_MONITOR_PID"
    if ! wait_for_file "$STATE_RECORD_MONITOR_READY"; then
        fail_test "$label state record monitor did not become ready"
    fi
}

function stop_state_record_monitor {
    local label="$1"
    local monitor_pid="$STATE_RECORD_MONITOR_PID"
    local report_file="$STATE_RECORD_MONITOR_REPORT"

    if [[ -z "$monitor_pid" ]]; then
        fail_test "no state record monitor is active"
    fi
    : > "$STATE_RECORD_MONITOR_STOP"
    wait "$monitor_pid"
    STATE_RECORD_MONITOR_PID=""
    STATE_RECORD_MONITOR_STOP=""
    STATE_RECORD_MONITOR_REPORT=""
    STATE_RECORD_MONITOR_READY=""
    if [[ -s "$report_file" ]]; then
        printf 'State record monitor report:\n' >&2
        sed -n '1,160p' "$report_file" >&2
        fail_test "$label observed an invalid state record"
    fi
}

function start_state_lock_holder {
    local label="$1"
    local state_directory="$2"

    if [[ -n "$STATE_LOCK_HOLDER_PID" ]]; then
        fail_test "a state lock holder is already active"
    fi
    STATE_LOCK_HOLDER_READY="$WORKSPACE/pty/$label-lock.ready"
    STATE_LOCK_HOLDER_RELEASE="$WORKSPACE/pty/$label-lock.release"
    rm -f -- "$STATE_LOCK_HOLDER_READY" "$STATE_LOCK_HOLDER_RELEASE"
    (
        local lock_fd=""

        exec {lock_fd}<"$state_directory"
        flock -x "$lock_fd"
        printf 'ready\n' > "$STATE_LOCK_HOLDER_READY"
        while [[ ! -e "$STATE_LOCK_HOLDER_RELEASE" ]]; do
            sleep "$POLL_INTERVAL_SECONDS"
        done
        flock -u "$lock_fd"
        exec {lock_fd}>&-
    ) &
    STATE_LOCK_HOLDER_PID=$!
    record_manifest pid "$STATE_LOCK_HOLDER_PID"
    if ! wait_for_file "$STATE_LOCK_HOLDER_READY"; then
        fail_test "$label state lock holder did not become ready"
    fi
}

function stop_state_lock_holder {
    local label="$1"
    local holder_pid="$STATE_LOCK_HOLDER_PID"

    if [[ -z "$holder_pid" ]]; then
        fail_test "no state lock holder is active"
    fi
    : > "$STATE_LOCK_HOLDER_RELEASE"
    wait "$holder_pid"
    STATE_LOCK_HOLDER_PID=""
    STATE_LOCK_HOLDER_RELEASE=""
    STATE_LOCK_HOLDER_READY=""
}

function start_gated_runner_outside {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local runner="$5"
    local target_session="$6"
    local target_id=""
    local gate_bin="$WORKSPACE/pty/$label-gate-bin"
    local gate_tmux="$gate_bin/tmux"

    shift 6
    target_id=$(session_id "$root" "$target_session")
    ATTACH_GATE_READY="$WORKSPACE/pty/$label-attach.ready"
    ATTACH_GATE_RELEASE="$WORKSPACE/pty/$label-attach.release"
    rm -f -- "$ATTACH_GATE_READY" "$ATTACH_GATE_RELEASE"
    mkdir -p -- "$gate_bin"
    # The generated wrapper expands these values when it runs.
    # shellcheck disable=SC2016
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -euo pipefail'
        printf '%s\n' 'joined=" $* "'
        printf '%s\n' 'if [[ "$joined" == *"if-shell "* ]] && [[ "$joined" == *"attach-session -t "* ]] && [[ "$joined" == *" -t '\''${TMUX_RUNNER_TEST_GATE_TARGET}:'\'' "* ]]; then'
        printf '%s\n' '    printf "ready\n" > "$TMUX_RUNNER_TEST_GATE_READY"'
        printf '%s\n' '    deadline=$((SECONDS + 10))'
        printf '%s\n' '    while [[ ! -e "$TMUX_RUNNER_TEST_GATE_RELEASE" ]] && (( SECONDS <= deadline )); do'
        printf '%s\n' '        sleep 0.01'
        printf '%s\n' '    done'
        printf '%s\n' '    if [[ ! -e "$TMUX_RUNNER_TEST_GATE_RELEASE" ]]; then'
        printf '%s\n' '        printf "attach gate timed out\n" >&2'
        printf '%s\n' '        exit 98'
        printf '%s\n' '    fi'
        printf '%s\n' 'fi'
        printf '%s\n' 'exec "$TMUX_RUNNER_TEST_REAL_TMUX" "$@"'
    } > "$gate_tmux"
    chmod 0755 "$gate_tmux"
    start_pty_command "$label" "$root" "$home" "$xdg_home" \
        env PATH="$gate_bin:$PATH" \
        TMUX_RUNNER_TEST_REAL_TMUX="$TMUX_PATH" \
        TMUX_RUNNER_TEST_GATE_TARGET="$target_id" \
        TMUX_RUNNER_TEST_GATE_READY="$ATTACH_GATE_READY" \
        TMUX_RUNNER_TEST_GATE_RELEASE="$ATTACH_GATE_RELEASE" \
        bash -x "$runner" "$@"
    if ! wait_for_file "$ATTACH_GATE_READY"; then
        fail_test "$label did not reach the attach gate"
    fi
}

function release_attach_gate {
    if [[ -z "$ATTACH_GATE_RELEASE" ]]; then
        fail_test "no attach gate is active"
    fi
    : > "$ATTACH_GATE_RELEASE"
}

function start_entry_gated_runner_outside {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local runner="$5"
    local gate_command="$6"
    local gate_bin="$WORKSPACE/pty/$label-entry-gate-bin"
    local gate_tmux="$gate_bin/tmux"

    shift 6
    ENTRY_GATE_READY="$WORKSPACE/pty/$label-entry.ready"
    ENTRY_GATE_RELEASE="$WORKSPACE/pty/$label-entry.release"
    ENTRY_GATE_DONE="$WORKSPACE/pty/$label-entry.done"
    rm -f -- "$ENTRY_GATE_READY" "$ENTRY_GATE_RELEASE" "$ENTRY_GATE_DONE"
    mkdir -p -- "$gate_bin"
    # The generated wrapper expands these values when it runs.
    # shellcheck disable=SC2016
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -euo pipefail'
        printf '%s\n' 'joined=" $* "'
        printf '%s\n' 'gated=0'
        printf '%s\n' 'if [[ "$joined" == *" ${TMUX_RUNNER_TEST_GATE_COMMAND} "* ]]; then'
        printf '%s\n' '    gated=1'
        printf '%s\n' '    printf "ready\n" > "$TMUX_RUNNER_TEST_GATE_READY"'
        printf '%s\n' '    deadline=$((SECONDS + 10))'
        printf '%s\n' '    while [[ ! -e "$TMUX_RUNNER_TEST_GATE_RELEASE" ]] && (( SECONDS <= deadline )); do'
        printf '%s\n' '        sleep 0.01'
        printf '%s\n' '    done'
        printf '%s\n' '    if [[ ! -e "$TMUX_RUNNER_TEST_GATE_RELEASE" ]]; then'
        printf '%s\n' '        printf "entry gate timed out\n" >&2'
        printf '%s\n' '        exit 98'
        printf '%s\n' '    fi'
        printf '%s\n' 'fi'
        printf '%s\n' 'tmux_rc=0'
        printf '%s\n' \
            '"$TMUX_RUNNER_TEST_REAL_TMUX" "$@" || tmux_rc=$?'
        printf '%s\n' 'if (( gated )); then'
        printf '%s\n' \
            '    printf "done\n" > "$TMUX_RUNNER_TEST_GATE_DONE"'
        printf '%s\n' 'fi'
        printf '%s\n' 'exit "$tmux_rc"'
    } > "$gate_tmux"
    chmod 0755 "$gate_tmux"
    start_pty_command "$label" "$root" "$home" "$xdg_home" \
        env PATH="$gate_bin:$PATH" \
        TMUX_RUNNER_TEST_REAL_TMUX="$TMUX_PATH" \
        TMUX_RUNNER_TEST_GATE_COMMAND="$gate_command" \
        TMUX_RUNNER_TEST_GATE_READY="$ENTRY_GATE_READY" \
        TMUX_RUNNER_TEST_GATE_RELEASE="$ENTRY_GATE_RELEASE" \
        TMUX_RUNNER_TEST_GATE_DONE="$ENTRY_GATE_DONE" \
        bash -x "$runner" "$@"
}

function invoke_runner_inside_entry_gated {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local source_session="$5"
    local runner="$6"
    local gate_bin="$WORKSPACE/pty/$label-inside-entry-gate-bin"
    local gate_tmux="$gate_bin/tmux"
    local runner_command=""
    local shell_command=""

    shift 6
    ENTRY_GATE_READY="$WORKSPACE/pty/$label-entry.ready"
    ENTRY_GATE_RELEASE="$WORKSPACE/pty/$label-entry.release"
    ENTRY_GATE_DONE="$WORKSPACE/pty/$label-entry.done"
    LAST_INSIDE_TRACE="$WORKSPACE/pty/$label.inside-trace"
    LAST_INSIDE_STATUS="$WORKSPACE/pty/$label.inside-status"
    rm -f -- "$ENTRY_GATE_READY" "$ENTRY_GATE_RELEASE" "$ENTRY_GATE_DONE"
    mkdir -p -- "$gate_bin"
    # The generated wrapper expands these values when it runs.
    # shellcheck disable=SC2016
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -euo pipefail'
        printf '%s\n' 'joined=" $* "'
        printf '%s\n' 'gated=0'
        printf '%s\n' \
            'if [[ "$joined" == *"if-shell "* ]] && [[ "$joined" == *"switch-client -t "* ]]; then'
        printf '%s\n' '    gated=1'
        printf '%s\n' \
            '    printf "ready\n" > "$TMUX_RUNNER_TEST_GATE_READY"'
        printf '%s\n' '    deadline=$((SECONDS + 10))'
        printf '%s\n' \
            '    while [[ ! -e "$TMUX_RUNNER_TEST_GATE_RELEASE" ]] && (( SECONDS <= deadline )); do'
        printf '%s\n' '        sleep 0.01'
        printf '%s\n' '    done'
        printf '%s\n' \
            '    if [[ ! -e "$TMUX_RUNNER_TEST_GATE_RELEASE" ]]; then'
        printf '%s\n' '        printf "entry gate timed out\n" >&2'
        printf '%s\n' '        exit 98'
        printf '%s\n' '    fi'
        printf '%s\n' 'fi'
        printf '%s\n' 'tmux_rc=0'
        printf '%s\n' \
            '"$TMUX_RUNNER_TEST_REAL_TMUX" "$@" || tmux_rc=$?'
        printf '%s\n' 'if (( gated )); then'
        printf '%s\n' \
            '    printf "done\n" > "$TMUX_RUNNER_TEST_GATE_DONE"'
        printf '%s\n' 'fi'
        printf '%s\n' 'exit "$tmux_rc"'
    } > "$gate_tmux"
    chmod 0755 "$gate_tmux"

    printf -v runner_command '%q ' env PATH="$gate_bin:$PATH" \
        TMUX_RUNNER_TEST_REAL_TMUX="$TMUX_PATH" \
        TMUX_RUNNER_TEST_GATE_READY="$ENTRY_GATE_READY" \
        TMUX_RUNNER_TEST_GATE_RELEASE="$ENTRY_GATE_RELEASE" \
        TMUX_RUNNER_TEST_GATE_DONE="$ENTRY_GATE_DONE" \
        HOME="$home" XDG_CONFIG_HOME="$xdg_home" TMUX_TMPDIR="$root" \
        bash -x "$runner" "$@"
    runner_command="${runner_command% }"
    printf -v shell_command \
        "set -o pipefail; %s 2>&1 | tee %q; runner_rc=\${PIPESTATUS[0]}; printf \"%%s\\n\" \"\$runner_rc\" > %q" \
        "$runner_command" "$LAST_INSIDE_TRACE" "$LAST_INSIDE_STATUS"
    run_tmux "$root" send-keys -t "$source_session:0.0" \
        -l -- "$shell_command"
    run_tmux "$root" send-keys -t "$source_session:0.0" C-m
}

function release_entry_gate {
    if [[ -z "$ENTRY_GATE_RELEASE" ]]; then
        fail_test "no entry gate is active"
    fi
    : > "$ENTRY_GATE_RELEASE"
}

function terminate_current_pty_as_crash {
    local pid="$CURRENT_PTY_PID"

    if [[ -z "$pid" ]]; then
        fail_test "no PTY process is active for crash injection"
    fi
    close_current_pty_input
    terminate_pty_process "$pid"
    CURRENT_PTY_PID=""
    LAST_PTY_RC=143
    ATTACH_GATE_READY=""
    ATTACH_GATE_RELEASE=""
}

function run_extra_outside_success {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local runner="$5"
    local expected_session="$6"
    local fifo="$WORKSPACE/pty/$label-extra.fifo"
    local transcript="$WORKSPACE/pty/$label-extra.typescript"
    local console="$WORKSPACE/pty/$label-extra.console"
    local command_string=""
    local fd=""
    local pid=""
    local rc=0

    shift 6
    if (( ${#EXTRA_PTY_PIDS[@]} > 0 || ${#EXTRA_PTY_FDS[@]} > 0 )); then
        fail_test "$label cannot start while another extra PTY is active"
    fi
    mkfifo -- "$fifo"
    printf -v command_string '%q ' bash -x "$runner" "$@"
    command_string="${command_string% }"
    setsid env -u TMUX HOME="$home" XDG_CONFIG_HOME="$xdg_home" \
        TMUX_TMPDIR="$root" SHELL=/bin/bash \
        timeout --foreground -k 2s "${PTY_TIMEOUT_SECONDS}s" \
        script -q -e -f -c "$command_string" "$transcript" \
        < "$fifo" > "$console" 2>&1 &
    pid=$!
    record_manifest pid "$pid"
    EXTRA_PTY_PIDS+=("$pid")
    exec {fd}>"$fifo"
    EXTRA_PTY_FDS+=("$fd")
    if ! wait_for_client_session "$root" "$expected_session"; then
        fail_test "$label extra runner did not reach $expected_session"
    fi
    run_tmux "$root" detach-client -s "=$expected_session"
    exec {fd}>&-
    wait "$pid" || rc=$?
    EXTRA_PTY_PIDS=()
    EXTRA_PTY_FDS=()
    assert_equal "0" "$rc" "$label extra runner failed"
}

function wait_for_client_set {
    local root="$1"
    local expected=""
    local actual=""
    local deadline=$((SECONDS + PTY_TIMEOUT_SECONDS))

    shift
    expected=$(printf '%s\n' "$@" | LC_ALL=C sort)
    while (( SECONDS <= deadline )); do
        actual=$(current_client_sessions "$root")
        if [[ "$actual" == "$expected" ]]; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

function start_concurrent_state_entries {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local runner="$5"
    local barrier_fifo="$WORKSPACE/pty/$label-state-barrier"
    local barrier_fd=""
    local session_name=""
    local ready_file=""
    local fifo=""
    local transcript=""
    local console=""
    local command_string=""
    local fd=""
    local pid=""
    local index=0
    # Positional parameters are expanded by the child Bash process.
    # shellcheck disable=SC2016
    local wrapper='printf "ready\n" > "$1"; IFS= read -r < "$2"; shift 2; exec "$@"'

    shift 5
    if (( ${#EXTRA_PTY_PIDS[@]} > 0 || ${#EXTRA_PTY_FDS[@]} > 0 )); then
        fail_test "$label cannot start while another extra PTY is active"
    fi
    BATCH_PTY_PIDS=()
    BATCH_PTY_FDS=()
    BATCH_SESSION_NAMES=("$@")
    mkfifo -- "$barrier_fifo"
    exec {barrier_fd}<>"$barrier_fifo"
    for session_name in "${BATCH_SESSION_NAMES[@]}"; do
        index=$((index + 1))
        ready_file="$WORKSPACE/pty/$label-$index.ready"
        fifo="$WORKSPACE/pty/$label-$index.fifo"
        transcript="$WORKSPACE/pty/$label-$index.typescript"
        console="$WORKSPACE/pty/$label-$index.console"
        mkfifo -- "$fifo"
        printf -v command_string '%q ' bash -c "$wrapper" state-entry \
            "$ready_file" "$barrier_fifo" bash -x "$runner" attach \
            "$session_name"
        command_string="${command_string% }"
        setsid env -u TMUX HOME="$home" XDG_CONFIG_HOME="$xdg_home" \
            TMUX_TMPDIR="$root" SHELL=/bin/bash \
            timeout --foreground -k 2s "${PTY_TIMEOUT_SECONDS}s" \
            script -q -e -f -c "$command_string" "$transcript" \
            < "$fifo" > "$console" 2>&1 &
        pid=$!
        record_manifest pid "$pid"
        BATCH_PTY_PIDS+=("$pid")
        EXTRA_PTY_PIDS+=("$pid")
        exec {fd}>"$fifo"
        BATCH_PTY_FDS+=("$fd")
        EXTRA_PTY_FDS+=("$fd")
    done
    index=0
    for session_name in "${BATCH_SESSION_NAMES[@]}"; do
        index=$((index + 1))
        if ! wait_for_file "$WORKSPACE/pty/$label-$index.ready"; then
            fail_test "$label runner for $session_name was not ready"
        fi
        printf '\n' >&"$barrier_fd"
    done
    exec {barrier_fd}>&-
    if ! wait_for_client_set "$root" "${BATCH_SESSION_NAMES[@]}"; then
        fail_test "$label did not attach every concurrent client"
    fi
}

function finish_concurrent_state_entries {
    local label="$1"
    local root="$2"
    local session_name=""
    local fd=""
    local pid=""
    local rc=0

    for session_name in "${BATCH_SESSION_NAMES[@]}"; do
        run_tmux "$root" detach-client -s "=$session_name"
    done
    for fd in "${BATCH_PTY_FDS[@]}"; do
        close_fd_number "$fd"
    done
    for pid in "${BATCH_PTY_PIDS[@]}"; do
        rc=0
        wait "$pid" || rc=$?
        assert_equal "0" "$rc" "$label concurrent runner failed"
    done
    BATCH_PTY_PIDS=()
    BATCH_PTY_FDS=()
    BATCH_SESSION_NAMES=()
    EXTRA_PTY_PIDS=()
    EXTRA_PTY_FDS=()
}

function create_ack_ticket_aba_wrappers {
    local gate_directory="$1"
    local wrapper_directory="$2"
    local tmux_wrapper="$wrapper_directory/tmux"
    local ln_wrapper="$wrapper_directory/ln"

    mkdir -p -- "$gate_directory" "$wrapper_directory"
    # The generated wrappers expand test-control values at runtime.
    # shellcheck disable=SC2016
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -euo pipefail'
        printf '%s\n' 'is_attach=0'
        printf '%s\n' 'joined=" $* "'
        printf '%s\n' 'target=""'
        printf '%s\n' 'for argument in "$@"; do'
        printf '%s\n' '    if [[ "$argument" == *" if-shell -F -t "* ]]; then'
        printf '%s\n' '        target="${argument#* if-shell -F -t }"'
        printf '%s\n' '        target="${target%% *}"'
        printf '%s\n' '        target="${target:1:${#target}-2}"'
        printf '%s\n' '        target="${target%:}"'
        printf '%s\n' '    fi'
        printf '%s\n' 'done'
        printf '%s\n' 'if [[ "$joined" == *"if-shell "* ]] && [[ "$joined" == *"attach-session -t "* ]]; then'
        printf '%s\n' '    is_attach=1'
        printf '%s\n' 'fi'
        printf '%s\n' 'if (( is_attach )); then'
        printf '%s\n' '    if [[ ! "$target" =~ ^\$[0-9]+$ ]]; then'
        printf '%s\n' '        printf "cannot resolve entry target\n" >&2'
        printf '%s\n' '        exit 96'
        printf '%s\n' '    fi'
        printf '%s\n' '    printf "ready\n" > "$TMUX_RUNNER_TEST_ABA_GATE/attach.$target"'
        printf '%s\n' '    deadline=$((SECONDS + TMUX_RUNNER_TEST_GATE_TIMEOUT))'
        printf '%s\n' '    while [[ ! -e "$TMUX_RUNNER_TEST_ABA_GATE/attach.release" ]] && (( SECONDS <= deadline )); do'
        printf '%s\n' '        sleep 0.01'
        printf '%s\n' '    done'
        printf '%s\n' '    if [[ ! -e "$TMUX_RUNNER_TEST_ABA_GATE/attach.release" ]]; then'
        printf '%s\n' '        printf "attach gate timed out\n" >&2'
        printf '%s\n' '        exit 98'
        printf '%s\n' '    fi'
        printf '%s\n' 'fi'
        printf '%s\n' 'exec "$TMUX_RUNNER_TEST_REAL_TMUX" "$@"'
    } > "$tmux_wrapper"
    # shellcheck disable=SC2016
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -euo pipefail'
        printf '%s\n' 'arguments=("$@")'
        printf '%s\n' 'argument_count=${#arguments[@]}'
        printf '%s\n' 'if (( argument_count >= 2 )); then'
        printf '%s\n' '    source_path="${arguments[argument_count - 2]}"'
        printf '%s\n' '    destination_path="${arguments[argument_count - 1]}"'
        printf '%s\n' '    destination_name="${destination_path##*/}"'
        printf '%s\n' '    if [[ "$destination_name" == .ack.ticket.* ]] && [[ ! -e "$TMUX_RUNNER_TEST_ABA_GATE/barrier.done" ]]; then'
        printf '%s\n' '        source_name="${source_path##*/.ack.tmp.}"'
        printf '%s\n' '        transaction_id="${source_name%%.*}"'
        printf '%s\n' '        attempt_directory="$TMUX_RUNNER_TEST_ABA_GATE/ticket.$transaction_id"'
        printf '%s\n' '        if mkdir -- "$attempt_directory" 2>/dev/null; then'
        printf '%s\n' '            printf "%s\n" "$destination_name" > "$attempt_directory/attempt"'
        printf '%s\n' '            deadline=$((SECONDS + TMUX_RUNNER_TEST_GATE_TIMEOUT))'
        printf '%s\n' '            while [[ ! -e "$TMUX_RUNNER_TEST_ABA_GATE/barrier.done" ]] && (( SECONDS <= deadline )); do'
        printf '%s\n' '                sleep 0.01'
        printf '%s\n' '            done'
        printf '%s\n' '            while [[ ! -e "$TMUX_RUNNER_TEST_ABA_GATE/release.$transaction_id" ]] && (( SECONDS <= deadline )); do'
        printf '%s\n' '                sleep 0.01'
        printf '%s\n' '            done'
        printf '%s\n' '            if [[ ! -e "$TMUX_RUNNER_TEST_ABA_GATE/release.$transaction_id" ]]; then'
        printf '%s\n' '                printf "ticket gate timed out\n" >&2'
        printf '%s\n' '                exit 97'
        printf '%s\n' '            fi'
        printf '%s\n' '        fi'
        printf '%s\n' '    fi'
        printf '%s\n' 'fi'
        printf '%s\n' 'exec "$TMUX_RUNNER_TEST_REAL_LN" "$@"'
    } > "$ln_wrapper"
    chmod 0755 -- "$tmux_wrapper" "$ln_wrapper"
}

function configure_ack_ticket_aba_server_environment {
    local root="$1"
    local gate_directory="$2"
    local wrapper_directory="$3"
    local wrapped_path="$wrapper_directory:$PATH"
    local real_ln=""

    real_ln=$(type -P ln)
    run_tmux "$root" set-environment -g PATH "$wrapped_path"
    run_tmux "$root" set-environment -g TMUX_RUNNER_TEST_ABA_GATE \
        "$gate_directory"
    run_tmux "$root" set-environment -g TMUX_RUNNER_TEST_REAL_TMUX \
        "$TMUX_PATH"
    run_tmux "$root" set-environment -g TMUX_RUNNER_TEST_REAL_LN \
        "$real_ln"
    run_tmux "$root" set-environment -g TMUX_RUNNER_TEST_GATE_TIMEOUT \
        "$PTY_TIMEOUT_SECONDS"
}

function start_ack_ticket_aba_entries {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local runner="$5"
    local state_directory="$6"
    local gate_directory="$7"
    local wrapper_directory="$8"
    local session_name=""
    local fifo=""
    local transcript=""
    local console=""
    local command_string=""
    local fd=""
    local pid=""
    local pending_file=""
    local real_ln=""
    local index=0
    local -a pending_files=()

    shift 8
    if (( ${#EXTRA_PTY_PIDS[@]} > 0 || ${#EXTRA_PTY_FDS[@]} > 0 )); then
        fail_test "$label cannot start while another extra PTY is active"
    fi
    real_ln=$(type -P ln)
    BATCH_PTY_PIDS=()
    BATCH_PTY_FDS=()
    BATCH_SESSION_NAMES=("$@")
    for session_name in "${BATCH_SESSION_NAMES[@]}"; do
        index=$((index + 1))
        fifo="$WORKSPACE/pty/$label-$index.fifo"
        transcript="$WORKSPACE/pty/$label-$index.typescript"
        console="$WORKSPACE/pty/$label-$index.console"
        mkfifo -- "$fifo"
        printf -v command_string '%q ' bash -x "$runner" attach \
            "$session_name"
        command_string="${command_string% }"
        setsid env -u TMUX HOME="$home" XDG_CONFIG_HOME="$xdg_home" \
            TMUX_TMPDIR="$root" SHELL=/bin/bash \
            PATH="$wrapper_directory:$PATH" \
            TMUX_RUNNER_TEST_ABA_GATE="$gate_directory" \
            TMUX_RUNNER_TEST_REAL_TMUX="$TMUX_PATH" \
            TMUX_RUNNER_TEST_REAL_LN="$real_ln" \
            TMUX_RUNNER_TEST_GATE_TIMEOUT="$PTY_TIMEOUT_SECONDS" \
            timeout --foreground -k 2s "${PTY_TIMEOUT_SECONDS}s" \
            script -q -e -f -c "$command_string" "$transcript" \
            < "$fifo" > "$console" 2>&1 &
        pid=$!
        record_manifest pid "$pid"
        BATCH_PTY_PIDS+=("$pid")
        EXTRA_PTY_PIDS+=("$pid")
        exec {fd}>"$fifo"
        BATCH_PTY_FDS+=("$fd")
        EXTRA_PTY_FDS+=("$fd")
    done
    if ! wait_for_named_file_count "$gate_directory" 'attach.*' 1 3; then
        fail_test "$label did not gate three attach-session calls"
    fi
    if ! wait_for_named_file_count "$state_directory" 'pending.*' 1 3; then
        fail_test "$label did not publish three pending state events"
    fi
    pending_files=("$state_directory"/pending.*)
    for pending_file in "${pending_files[@]}"; do
        assert_versioned_transaction_record "$pending_file" \
            "$label pending state event"
    done
    printf 'release\n' > "$gate_directory/attach.release"
    if ! wait_for_named_file_count "$gate_directory" attempt 2 3; then
        fail_test "$label did not gate three first ticket attempts"
    fi
    if ! wait_for_client_set "$root" "${BATCH_SESSION_NAMES[@]}"; then
        fail_test "$label did not attach every gated client"
    fi
}

function exercise_navigation_concurrency_ack_ticket_aba {
    local root=""
    local home="$WORKSPACE/navigation-concurrency-aba/home"
    local xdg_home="$WORKSPACE/navigation-concurrency-aba/xdg"
    local state_home="$WORKSPACE/navigation-concurrency-aba/state-home"
    local state_directory=""
    local state_file=""
    local gate_directory="$WORKSPACE/navigation-concurrency-aba/gate"
    local wrapper_directory="$WORKSPACE/navigation-concurrency-aba/wrappers"
    local session_root="$WORKSPACE/navigation-concurrency-aba/sessions"
    local session_name=""
    local session_path=""
    local attempt_file=""
    local attempt_directory=""
    local ticket_name=""
    local first_ticket_name=""
    local transaction_id=""
    local row_sequence=""
    local acknowledgment_sequences=""
    local unique_sequence_count=0
    local index=0
    local -a session_names=()
    local -a session_paths=()
    local -a attempt_files=()

    create_tmux_root navigation-concurrency-aba
    root="$NEW_TMUX_ROOT"
    export XDG_STATE_HOME="$state_home"
    state_directory=$(runner_state_directory_for "$state_home")
    state_file="$state_directory/state"
    mkdir -p -- "$home" "$xdg_home" "$session_root"

    for ((index = 1; index <= 3; index++)); do
        session_name="m6-aba-$index"
        session_path="$session_root/path-$index"
        session_names+=("$session_name")
        session_paths+=("$session_path")
        mkdir -p -- "$session_path"
        if (( index == 1 )); then
            run_tmux "$root" -f /dev/null new-session -d \
                -s "$session_name" -c "$session_path"
        else
            run_tmux "$root" new-session -d -s "$session_name" \
                -c "$session_path"
        fi
        run_tmux "$root" set-option -t "=$session_name:" \
            @tmux-runner-path "$session_path"
    done

    create_ack_ticket_aba_wrappers "$gate_directory" "$wrapper_directory"
    configure_ack_ticket_aba_server_environment "$root" \
        "$gate_directory" "$wrapper_directory"
    start_ack_ticket_aba_entries navigation-concurrency-aba "$root" "$home" \
        "$xdg_home" "$RUNNER" "$state_directory" "$gate_directory" \
        "$wrapper_directory" "${session_names[@]}"

    mapfile -t attempt_files < <(
        find "$gate_directory" -mindepth 2 -maxdepth 2 -type f \
            -name attempt -print | LC_ALL=C sort
    )
    assert_equal "3" "${#attempt_files[@]}" \
        "ticket ABA barrier did not capture three attempts"
    for attempt_file in "${attempt_files[@]}"; do
        ticket_name=$(<"$attempt_file")
        if [[ ! "$ticket_name" =~ ^\.ack\.ticket\.[0-9]+$ ]]; then
            fail_test "ticket ABA barrier captured a malformed ticket name"
        fi
        if [[ -z "$first_ticket_name" ]]; then
            first_ticket_name="$ticket_name"
        else
            assert_equal "$first_ticket_name" "$ticket_name" \
                "ticket ABA attempts did not precompute one sequence"
        fi
    done

    printf 'ready\n' > "$gate_directory/barrier.done"
    for attempt_file in "${attempt_files[@]}"; do
        attempt_directory="${attempt_file%/attempt}"
        transaction_id="${attempt_directory##*/ticket.}"
        printf 'release\n' > "$gate_directory/release.$transaction_id"
        if ! wait_for_path_absent \
            "$state_directory/pending.$transaction_id"; then
            fail_test "ticket ABA transaction did not settle"
        fi
        sleep 0.5
    done

    if ! wait_for_state_row_count "$state_file" recent 3; then
        fail_test "ticket ABA updates did not retain three recent paths"
    fi
    finish_concurrent_state_entries navigation-concurrency-aba "$root"
    if ! wait_for_no_state_transactions "$state_directory"; then
        fail_test "ticket ABA run left transaction or ticket debris"
    fi
    for session_path in "${session_paths[@]}"; do
        row_sequence=$(awk -F '\t' \
            -v path="$(encode_state_field "$session_path")" \
            '$1 == "recent" && NF == 4 && $4 == path { print $2 }' \
            "$state_file")
        if [[ ! "$row_sequence" =~ ^[0-9]+$ ]]; then
            fail_test "ticket ABA recent row has no single valid sequence"
        fi
        if [[ -n "$acknowledgment_sequences" ]]; then
            acknowledgment_sequences+=$'\n'
        fi
        acknowledgment_sequences+="$row_sequence"
    done
    unique_sequence_count=$(printf '%s\n' "$acknowledgment_sequences" | \
        LC_ALL=C sort -u | awk 'NF { count++ } END { print count + 0 }')
    assert_equal "3" "$unique_sequence_count" \
        "successful acknowledgments reused a deleted ticket sequence"
    if ! validate_main_state_record "$state_file"; then
        fail_test "ticket ABA run left an invalid main state record"
    fi
    assert_state_modes "$state_directory"
    assert_no_state_transactions "$state_directory"
    unset XDG_STATE_HOME
}

function test_t1_static {
    assert_command_succeeds "runner Bash syntax failed" bash -n "$RUNNER"
    assert_command_succeeds "completion Bash syntax failed" bash -n "$COMPLETION"
    assert_command_succeeds "version injector Bash syntax failed" \
        bash -n "$VERSION_INJECTOR"
    assert_command_succeeds "test Bash syntax failed" bash -n "$TEST_DIR/test-tmux-runner.bash"
    assert_command_succeeds "runner ShellCheck reported a finding" \
        shellcheck "$RUNNER"
    assert_command_succeeds "completion ShellCheck reported a finding" \
        shellcheck -s bash "$COMPLETION"
    assert_command_succeeds "version injector ShellCheck reported a finding" \
        shellcheck "$VERSION_INJECTOR"
    assert_command_succeeds "test ShellCheck reported a finding" \
        shellcheck "$TEST_DIR/test-tmux-runner.bash"
    pass_test T1 "Bash syntax and ShellCheck"
}

function test_t2_create {
    local root=""
    local home=""
    local xdg_home=""
    local default_dir=""
    local alias_dir=""
    local named_dir=""
    local folder_only_dir=""
    local inside_dir=""
    local concurrent_dir=""
    local short_hostname=""
    local default_name=""
    local folder_only_name=""
    local identity_before=""
    local recent_before_unmarked=""
    local fingerprint_before=""
    local socket_path=""

    create_tmux_root t2
    root="$NEW_TMUX_ROOT"
    home="$WORKSPACE/t2/home"
    xdg_home="$WORKSPACE/t2/xdg"
    default_dir="$WORKSPACE/t2/default.repo"
    alias_dir="$WORKSPACE/t2/alias-folder"
    named_dir="$WORKSPACE/t2/named-current-folder"
    folder_only_dir="$WORKSPACE/t2/folder-only"
    inside_dir="$WORKSPACE/t2/inside-folder"
    concurrent_dir="$WORKSPACE/t2/concurrent-folder"
    mkdir -p -- "$home" "$xdg_home" "$default_dir" "$alias_dir" \
        "$named_dir" "$folder_only_dir" "$inside_dir" "$concurrent_dir"

    socket_path=$(find "$root" -type s -print -quit)
    assert_equal "" "$socket_path" "T2 did not begin without a server socket"
    short_hostname=$(hostname -s)
    short_hostname="${short_hostname//./_}"
    short_hostname="${short_hostname//:/_}"
    default_name="default_repo-$short_hostname"
    folder_only_name="folder-only-$short_hostname"

    pushd "$default_dir" >/dev/null
    start_runner_outside t2-default "$root" "$home" "$xdg_home" \
        "$RUNNER" create
    if ! wait_for_transcript_text \
        "+ run_tmux_command has-session -t =$default_name"; then
        fail_test "cold create did not reach its first tmux lookup"
    fi
    if ! wait_for_client_session "$root" "$default_name"; then
        fail_test "cold create did not attach"
    fi
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "cold create failed"
    popd >/dev/null
    assert_equal "$default_dir" "$(pane_directory "$root" "$default_name")" \
        "default create used the wrong directory"

    run_outside_success t2-alias-create "$root" "$home" "$xdg_home" \
        "$RUNNER" alias_session_blue c -s alias.session:blue -c "$alias_dir"
    assert_session_entry_trace "$LAST_TRANSCRIPT" "$root" \
        alias_session_blue "c did not target the resolved session ID"
    assert_contains "$LAST_TRANSCRIPT" \
        "$TMUX_RUNNER_TRACE_PREFIX new-session -d -s alias_session_blue" \
        "alias create did not normalize the session name"
    identity_before=$(session_identity "$root" alias_session_blue)
    run_outside_success t2-alias-reuse "$root" "$home" "$xdg_home" \
        "$RUNNER" alias_session_blue create -s alias.session:blue -c "$alias_dir"
    assert_session_entry_trace "$LAST_TRANSCRIPT" "$root" \
        alias_session_blue "create did not target the resolved session ID"
    assert_equal "$identity_before" "$(session_identity "$root" alias_session_blue)" \
        "existing session reuse changed its identifiers"
    assert_not_contains "$LAST_TRANSCRIPT" \
        "$TMUX_RUNNER_TRACE_PREFIX new-session" \
        "existing session reuse created another session"

    pushd "$named_dir" >/dev/null
    run_outside_success t2-named "$root" "$home" "$xdg_home" \
        "$RUNNER" named-session create -s named-session
    popd >/dev/null
    assert_equal "$named_dir" "$(pane_directory "$root" named-session)" \
        "-s-only create used the wrong directory"

    run_outside_success t2-folder-only "$root" "$home" "$xdg_home" \
        "$RUNNER" "$folder_only_name" create -c "$folder_only_dir"
    assert_equal "$folder_only_dir" \
        "$(pane_directory "$root" "$folder_only_name")" \
        "-c-only create used the wrong directory"

    run_tmux "$root" new-session -d -s prefix-target-long
    run_outside_success t2-prefix "$root" "$home" "$xdg_home" \
        "$RUNNER" prefix-target create -s prefix-target -c "$named_dir"
    assert_equal "$named_dir" "$(session_path "$root" prefix-target)" \
        "full-name option lookup selected the prefix sibling"
    assert_equal "" \
        "$(run_tmux "$root" show-options -qv -t '=prefix-target-long:' \
            @tmux-runner-path 2>/dev/null || true)" \
        "exact option target changed the prefix sibling"
    run_tmux "$root" new-session -d -s source-create
    run_inside_success t2-inside-new "$root" "$home" "$xdg_home" \
        source-create inside_new "$RUNNER" create -s inside.new -c "$inside_dir"
    assert_session_entry_trace "$LAST_INSIDE_TRACE" "$root" inside_new \
        "inside create did not use an exact switch target"

    identity_before=$(session_identity "$root" alias_session_blue)
    run_inside_success t2-inside-reuse "$root" "$home" "$xdg_home" \
        source-create alias_session_blue "$RUNNER" c -s alias.session:blue \
        -c "$alias_dir"
    assert_equal "$identity_before" "$(session_identity "$root" alias_session_blue)" \
        "inside reuse changed existing session identifiers"
    assert_not_contains "$LAST_INSIDE_TRACE" \
        "$TMUX_RUNNER_TRACE_PREFIX new-session" \
        "inside reuse created another session"

    run_concurrent_create t2-concurrent "$root" "$home" "$xdg_home" \
        "$RUNNER" concurrent-session "$concurrent_dir"
    assert_equal "$concurrent_dir" \
        "$(pane_directory "$root" concurrent-session)" \
        "concurrent create used the wrong directory"

    fingerprint_before=$(server_fingerprint "$root")
    run_outside_create_syntax_failure t2-invalid-extra "$root" "$home" \
        "$xdg_home" "$RUNNER" create extra
    assert_equal "$fingerprint_before" "$(server_fingerprint "$root")" \
        "create extra changed server state"
    run_outside_create_syntax_failure t2-invalid-session-duplicate "$root" \
        "$home" "$xdg_home" "$RUNNER" create -s alias.session:blue \
        -s named-session
    assert_equal "$fingerprint_before" "$(server_fingerprint "$root")" \
        "duplicate -s changed server state"
    run_outside_create_syntax_failure t2-invalid-directory-duplicate "$root" \
        "$home" "$xdg_home" "$RUNNER" create -c "$alias_dir" \
        -c "$folder_only_dir"
    assert_equal "$fingerprint_before" "$(server_fingerprint "$root")" \
        "duplicate -c changed server state"

    assert_session_set "$root" "T2 session set is wrong" \
        "$default_name" alias_session_blue named-session "$folder_only_name" \
        prefix-target-long prefix-target source-create inside_new \
        concurrent-session
    pass_test T2 "create, reuse, concurrent create, and exact switching"
}

function test_t3_attach {
    local root=""
    local home=""
    local xdg_home=""
    local fingerprint_before=""

    create_tmux_root t3
    root="$NEW_TMUX_ROOT"
    home="$WORKSPACE/t3/home"
    xdg_home="$WORKSPACE/t3/xdg"
    mkdir -p -- "$home" "$xdg_home"
    run_tmux "$root" -f /dev/null new-session -d -s target
    run_tmux "$root" new-session -d -s source
    run_tmux "$root" new-session -d -s dotted_target_blue
    run_tmux "$root" new-session -d -s prefix-only-long

    run_outside_success t3-attach-t "$root" "$home" "$xdg_home" \
        "$RUNNER" target attach -t target
    assert_session_entry_trace "$LAST_TRANSCRIPT" "$root" target \
        "attach -t did not use the exact target"
    run_outside_success t3-attach-positional "$root" "$home" "$xdg_home" \
        "$RUNNER" target attach target
    run_outside_success t3-a-t "$root" "$home" "$xdg_home" \
        "$RUNNER" target a -t target
    assert_session_entry_trace "$LAST_TRANSCRIPT" "$root" target \
        "a did not target the resolved session ID"
    run_outside_success t3-a-positional "$root" "$home" "$xdg_home" \
        "$RUNNER" target a target
    run_outside_success t3-attach-terminator "$root" "$home" "$xdg_home" \
        "$RUNNER" target attach -- target
    run_outside_success t3-a-terminator "$root" "$home" "$xdg_home" \
        "$RUNNER" target a -- target

    run_inside_success t3-inside-attach-t "$root" "$home" "$xdg_home" \
        source target "$RUNNER" attach -t target
    assert_session_entry_trace "$LAST_INSIDE_TRACE" "$root" target \
        "inside attach -t did not use the exact target"
    run_inside_success t3-inside-attach-positional "$root" "$home" \
        "$xdg_home" source target "$RUNNER" attach target
    run_inside_success t3-inside-a-t "$root" "$home" "$xdg_home" \
        source target "$RUNNER" a -t target
    run_inside_success t3-inside-a-positional "$root" "$home" "$xdg_home" \
        source target "$RUNNER" a target
    run_inside_success t3-inside-attach-terminator "$root" "$home" \
        "$xdg_home" source target "$RUNNER" attach -- target
    run_inside_success t3-inside-a-terminator "$root" "$home" "$xdg_home" \
        source target "$RUNNER" a -- target

    run_outside_success t3-dotted-outside "$root" "$home" "$xdg_home" \
        "$RUNNER" dotted_target_blue attach dotted.target:blue
    assert_session_entry_trace "$LAST_TRANSCRIPT" "$root" \
        dotted_target_blue \
        "outside attach did not normalize separators"
    run_inside_success t3-dotted-inside "$root" "$home" "$xdg_home" \
        source dotted_target_blue "$RUNNER" a -t dotted.target:blue
    assert_session_entry_trace "$LAST_INSIDE_TRACE" "$root" \
        dotted_target_blue \
        "inside attach did not normalize separators"

    fingerprint_before=$(server_fingerprint "$root")
    run_outside_syntax_failure t3-invalid-attach-empty "$root" "$home" "$xdg_home" \
        "$RUNNER" attach
    assert_contains "$LAST_TRANSCRIPT" \
        "tmux-runner attach -t <session-name>" \
        "attach missing-target guidance omitted -t form"
    assert_contains "$LAST_TRANSCRIPT" \
        "tmux-runner attach <session-name>" \
        "attach missing-target guidance omitted positional form"
    assert_contains "$LAST_TRANSCRIPT" \
        "tmux-runner attach -- <session-name>" \
        "attach missing-target guidance omitted terminator form"
    run_outside_syntax_failure t3-invalid-a-empty "$root" "$home" "$xdg_home" \
        "$RUNNER" a
    assert_contains "$LAST_TRANSCRIPT" "tmux-runner a -t <session-name>" \
        "a missing-target guidance omitted -t form"
    assert_contains "$LAST_TRANSCRIPT" "tmux-runner a <session-name>" \
        "a missing-target guidance omitted positional form"
    assert_contains "$LAST_TRANSCRIPT" "tmux-runner a -- <session-name>" \
        "a missing-target guidance omitted terminator form"
    run_outside_syntax_failure t3-invalid-attach-mixed "$root" "$home" "$xdg_home" \
        "$RUNNER" attach -t target target
    run_outside_syntax_failure t3-invalid-a-mixed "$root" "$home" "$xdg_home" \
        "$RUNNER" a -t target target
    run_outside_syntax_failure t3-invalid-attach-extra "$root" "$home" "$xdg_home" \
        "$RUNNER" attach target extra
    run_outside_syntax_failure t3-invalid-a-extra "$root" "$home" "$xdg_home" \
        "$RUNNER" a target extra
    run_outside_syntax_failure t3-invalid-attach-terminator-extra "$root" \
        "$home" "$xdg_home" "$RUNNER" attach -- target extra
    run_outside_syntax_failure t3-invalid-a-terminator-extra "$root" "$home" \
        "$xdg_home" "$RUNNER" a -- target extra
    assert_equal "$fingerprint_before" "$(server_fingerprint "$root")" \
        "outside invalid attach cases changed server state"

    run_inside_syntax_failure t3-inside-invalid-attach-empty "$root" "$home" \
        "$xdg_home" source "$RUNNER" attach
    run_inside_syntax_failure t3-inside-invalid-a-empty "$root" "$home" \
        "$xdg_home" source "$RUNNER" a
    run_inside_syntax_failure t3-inside-invalid-attach-mixed "$root" "$home" \
        "$xdg_home" source "$RUNNER" attach -t target target
    run_inside_syntax_failure t3-inside-invalid-a-mixed "$root" "$home" \
        "$xdg_home" source "$RUNNER" a -t target target
    run_inside_syntax_failure t3-inside-invalid-attach-extra "$root" "$home" \
        "$xdg_home" source "$RUNNER" attach target extra
    run_inside_syntax_failure t3-inside-invalid-a-extra "$root" "$home" \
        "$xdg_home" source "$RUNNER" a target extra
    run_inside_syntax_failure t3-inside-invalid-attach-terminator-extra \
        "$root" "$home" "$xdg_home" source "$RUNNER" attach -- target extra
    run_inside_syntax_failure t3-inside-invalid-a-terminator-extra "$root" \
        "$home" "$xdg_home" source "$RUNNER" a -- target extra
    assert_equal "$fingerprint_before" "$(server_fingerprint "$root")" \
        "inside invalid attach cases changed server state"

    run_outside_failure t3-prefix-missing-outside "$root" "$home" "$xdg_home" \
        "$RUNNER" attach prefix-only
    assert_contains "$LAST_TRANSCRIPT" \
        "display-message -p -t =prefix-only:" \
        "missing exact target was not resolved exactly"
    run_inside_failure t3-prefix-missing-inside "$root" "$home" "$xdg_home" \
        source "$RUNNER" a -t prefix-only
    assert_contains "$LAST_INSIDE_TRACE" \
        "display-message -p -t =prefix-only:" \
        "missing exact inside target was not resolved exactly"

    assert_session_set "$root" "T3 session set changed" \
        source target dotted_target_blue prefix-only-long
    pass_test T3 "outside and inside attachment forms and failures"
}

function test_t4_list {
    local selected_root=""
    local other_root=""
    local home=""
    local xdg_home=""
    local expected_rows=""
    local number=""
    local fingerprint_before=""
    local inside_status=""

    create_tmux_root t4-selected
    selected_root="$NEW_TMUX_ROOT"
    create_tmux_root t4-other
    other_root="$NEW_TMUX_ROOT"
    home="$WORKSPACE/t4/home"
    xdg_home="$WORKSPACE/t4/xdg"
    mkdir -p -- "$home" "$xdg_home"
    run_tmux "$selected_root" -f /dev/null new-session -d -s alpha
    run_tmux "$selected_root" new-session -d -s gamma
    run_tmux "$other_root" -f /dev/null new-session -d -s beta

    expected_rows=$(run_tmux "$selected_root" list-sessions)
    start_runner_outside t4-alpha "$selected_root" "$home" "$xdg_home" \
        "$RUNNER" ls
    if ! wait_for_transcript_text "Select session:"; then
        fail_test "outside ls did not display its prompt"
    fi
    assert_rows_visible "$LAST_TRANSCRIPT" "$expected_rows"
    assert_not_contains "$LAST_TRANSCRIPT" "beta:" \
        "ls displayed a session from another UDS"
    number=$(selection_number "$LAST_TRANSCRIPT" alpha)
    if [[ -z "$number" ]]; then
        fail_test "alpha selection number was not displayed"
    fi
    send_current_input "$number\n"
    if ! wait_for_client_session "$selected_root" alpha; then
        fail_test "outside ls did not attach to alpha"
    fi
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "alpha ls selection failed"
    assert_session_entry_trace "$LAST_TRANSCRIPT" "$selected_root" alpha \
        "alpha selection did not use the exact target"

    expected_rows=$(run_tmux "$selected_root" list-sessions)
    start_runner_outside t4-gamma "$selected_root" "$home" "$xdg_home" \
        "$RUNNER" ls
    if ! wait_for_transcript_text "Select session:"; then
        fail_test "gamma ls did not display its prompt"
    fi
    assert_rows_visible "$LAST_TRANSCRIPT" "$expected_rows"
    number=$(selection_number "$LAST_TRANSCRIPT" gamma)
    if [[ -z "$number" ]]; then
        fail_test "gamma selection number was not displayed"
    fi
    send_current_input "$number\n"
    if ! wait_for_client_session "$selected_root" gamma; then
        fail_test "outside ls did not attach to gamma"
    fi
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "gamma ls selection failed"

    start_source_client t4-inside "$selected_root" "$home" "$xdg_home" alpha
    expected_rows=$(run_tmux "$selected_root" list-sessions)
    invoke_runner_inside t4-inside "$selected_root" "$home" "$xdg_home" \
        alpha "$RUNNER" ls
    if ! wait_for_file_text "$LAST_INSIDE_TRACE" "Select session:"; then
        fail_test "inside ls did not display its prompt"
    fi
    assert_rows_visible "$LAST_INSIDE_TRACE" "$expected_rows"
    number=$(selection_number "$LAST_INSIDE_TRACE" gamma)
    if [[ -z "$number" ]]; then
        fail_test "inside gamma selection number was not displayed"
    fi
    send_current_input "$number\n"
    if ! wait_for_client_session "$selected_root" gamma; then
        fail_test "inside ls did not switch to gamma"
    fi
    if ! wait_for_file "$LAST_INSIDE_STATUS"; then
        fail_test "inside ls did not record status"
    fi
    inside_status=$(inside_runner_status)
    assert_equal "0" "$inside_status" "inside ls returned nonzero"
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "inside ls client failed"
    assert_session_entry_trace "$LAST_INSIDE_TRACE" "$selected_root" gamma \
        "inside ls did not use the exact switch target"

    fingerprint_before=$(server_fingerprint "$selected_root")
    start_state_monitor t4-invalid-text "$selected_root"
    start_runner_outside t4-invalid-text "$selected_root" "$home" "$xdg_home" \
        "$RUNNER" ls
    if ! wait_for_transcript_text "Select session:"; then
        fail_test "invalid text ls did not display its prompt"
    fi
    send_current_input 'not-a-number\n'
    finish_current_pty
    stop_state_monitor t4-invalid-text
    assert_last_pty_failed_without_timeout "nonnumeric ls input"
    start_state_monitor t4-invalid-range "$selected_root"
    start_runner_outside t4-invalid-range "$selected_root" "$home" "$xdg_home" \
        "$RUNNER" ls
    if ! wait_for_transcript_text "Select session:"; then
        fail_test "invalid range ls did not display its prompt"
    fi
    send_current_input '18446744073709551617\n'
    finish_current_pty
    stop_state_monitor t4-invalid-range
    assert_last_pty_failed_without_timeout "out-of-range ls input"
    assert_equal "$fingerprint_before" "$(server_fingerprint "$selected_root")" \
        "invalid ls input changed server state"
    assert_equal "" "$(current_client_sessions "$selected_root")" \
        "invalid ls input attached a client"

    pass_test T4 "full-row UDS selection and input validation"
}

function test_t5_completion {
    local selected_root=""
    local other_root=""
    local completion_dir=""

    create_tmux_root t5-selected
    selected_root="$NEW_TMUX_ROOT"
    create_tmux_root t5-other
    other_root="$NEW_TMUX_ROOT"
    run_tmux "$selected_root" -f /dev/null new-session -d -s alpha
    run_tmux "$selected_root" new-session -d -s -dash
    run_tmux "$other_root" -f /dev/null new-session -d -s beta
    completion_dir="$WORKSPACE/t5/completion-dir"
    mkdir -p -- "$completion_dir/work-dir"
    : > "$completion_dir/work-file"

    unset TMUX || true
    export TMUX_TMPDIR="$selected_root"
    # The completion path is resolved from the shipped repository under test.
    # shellcheck disable=SC1090,SC1091
    source "$COMPLETION"

    COMP_WORDS=(tmux-runner "")
    COMP_CWORD=1
    _tmux_runner
    assert_reply_set "command completion set is wrong" \
        create c repo recent last ls attach a -V --version -h --help

    COMP_WORDS=(tmux-runner create -)
    COMP_CWORD=2
    _tmux_runner
    assert_reply_set "create option completion set is wrong" -s -c -h --help
    COMP_WORDS=(tmux-runner c -)
    COMP_CWORD=2
    _tmux_runner
    assert_reply_set "c option completion set is wrong" -s -c -h --help
    COMP_WORDS=(tmux-runner ls -)
    COMP_CWORD=2
    _tmux_runner
    assert_reply_set "ls option completion set is wrong" -h --help
    COMP_WORDS=(tmux-runner repo -)
    COMP_CWORD=2
    _tmux_runner
    assert_reply_set "repo option completion set is wrong" -h --help
    COMP_WORDS=(tmux-runner recent -)
    COMP_CWORD=2
    _tmux_runner
    assert_reply_set "recent option completion set is wrong" -h --help
    COMP_WORDS=(tmux-runner last -)
    COMP_CWORD=2
    _tmux_runner
    assert_reply_set "last option completion set is wrong" -h --help
    COMP_WORDS=(tmux-runner attach -)
    COMP_CWORD=2
    _tmux_runner
    assert_reply_set "attach option completion set is wrong" -t -- -h --help
    COMP_WORDS=(tmux-runner a -)
    COMP_CWORD=2
    _tmux_runner
    assert_reply_set "a option completion set is wrong" -t -- -h --help

    pushd "$completion_dir" >/dev/null
    COMP_WORDS=(tmux-runner create -c work-)
    COMP_CWORD=3
    _tmux_runner
    assert_reply_set "create directory completion set is wrong" work-dir
    COMP_WORDS=(tmux-runner c -c work-)
    COMP_CWORD=3
    _tmux_runner
    assert_reply_set "c directory completion set is wrong" work-dir
    popd >/dev/null

    COMP_WORDS=(tmux-runner attach -t a)
    COMP_CWORD=3
    _tmux_runner
    assert_reply_set "attach -t session completion set is wrong" alpha
    COMP_WORDS=(tmux-runner a -t a)
    COMP_CWORD=3
    _tmux_runner
    assert_reply_set "a -t session completion set is wrong" alpha
    COMP_WORDS=(tmux-runner attach a)
    COMP_CWORD=2
    _tmux_runner
    assert_reply_set "attach positional completion set is wrong" alpha
    COMP_WORDS=(tmux-runner a a)
    COMP_CWORD=2
    _tmux_runner
    assert_reply_set "a positional completion set is wrong" alpha
    COMP_WORDS=(tmux-runner attach -- a)
    COMP_CWORD=3
    _tmux_runner
    assert_reply_set "attach terminator completion set is wrong" alpha
    COMP_WORDS=(tmux-runner a -- a)
    COMP_CWORD=3
    _tmux_runner
    assert_reply_set "a terminator completion set is wrong" alpha
    COMP_WORDS=(tmux-runner attach -t -)
    COMP_CWORD=3
    _tmux_runner
    assert_reply_set "attach -t dash session completion is wrong" -dash
    COMP_WORDS=(tmux-runner a -t -)
    COMP_CWORD=3
    _tmux_runner
    assert_reply_set "a -t dash session completion is wrong" -dash
    COMP_WORDS=(tmux-runner attach -- -)
    COMP_CWORD=3
    _tmux_runner
    assert_reply_set "attach terminator dash completion is wrong" -dash
    COMP_WORDS=(tmux-runner a -- -)
    COMP_CWORD=3
    _tmux_runner
    assert_reply_set "a terminator dash completion is wrong" -dash

    pass_test T5 "command, option, directory, and selected-UDS completion"
}

function test_t6_install {
    local root=""
    local home=""
    local xdg_home=""
    local installed_runner=""
    local installed_completion=""
    local installed_config=""
    local inventory=""
    local expected_inventory=""
    local source_normalized=""
    local installed_normalized=""
    local version_output=""
    local expected_hash=""
    local commit_timestamp=""
    local expected_commit_date=""
    local install_date=""
    local install_epoch=0
    local install_before=0
    local install_after=0
    local preserved_config=""

    create_tmux_root t6
    root="$NEW_TMUX_ROOT"
    home="$WORKSPACE/t6/home with space"
    xdg_home="$WORKSPACE/t6/xdg config with space"
    mkdir -p -- "$home" "$xdg_home"
    installed_runner="$home/.local/bin/tmux-runner"
    installed_completion="$home/.local/share/bash-completion/completions/tmux-runner"
    installed_config="$xdg_home/tmux-runner/tmux.conf"
    preserved_config="$WORKSPACE/t6/preserved-tmux.conf"
    source_normalized="$WORKSPACE/t6/source.normalized"
    installed_normalized="$WORKSPACE/t6/installed.normalized"

    install_before=$(date -u '+%s')
    assert_command_succeeds "make install failed" \
        env XDG_CONFIG_HOME="$xdg_home" \
        make -C "$REPO_ROOT" HOME="$home" install
    inventory=$(find "$home" "$xdg_home" \( -type f -o -type l \) \
        -print | LC_ALL=C sort)
    expected_inventory=$(printf '%s\n%s\n%s\n' \
        "$installed_runner" "$installed_completion" "$installed_config" | \
        LC_ALL=C sort)
    assert_equal "$expected_inventory" "$inventory" \
        "install wrote an unexpected file"
    assert_equal "0755" "0$(stat -c '%a' "$installed_runner")" \
        "installed runner mode is wrong"
    assert_equal "0644" "0$(stat -c '%a' "$installed_completion")" \
        "installed completion mode is wrong"
    assert_equal "0644" "0$(stat -c '%a' "$installed_config")" \
        "installed config mode is wrong"
    sed -e 's/^readonly RUNNER_GIT_HASH=.*/readonly RUNNER_GIT_HASH="normalized"/' \
        -e 's/^readonly RUNNER_COMMIT_DATE=.*/readonly RUNNER_COMMIT_DATE="normalized"/' \
        -e 's/^readonly RUNNER_INSTALL_DATE=.*/readonly RUNNER_INSTALL_DATE="normalized"/' \
        "$SOURCE_RUNNER" > "$source_normalized"
    sed -e 's/^readonly RUNNER_GIT_HASH=.*/readonly RUNNER_GIT_HASH="normalized"/' \
        -e 's/^readonly RUNNER_COMMIT_DATE=.*/readonly RUNNER_COMMIT_DATE="normalized"/' \
        -e 's/^readonly RUNNER_INSTALL_DATE=.*/readonly RUNNER_INSTALL_DATE="normalized"/' \
        "$installed_runner" > "$installed_normalized"
    assert_command_succeeds \
        "installed runner differs outside injected metadata" \
        cmp -s "$source_normalized" "$installed_normalized"
    assert_command_succeeds \
        "installed completion differs from shipped completion" \
        cmp -s "$SOURCE_COMPLETION" "$installed_completion"
    assert_command_succeeds \
        "installed config differs from shipped config" \
        cmp -s "$RUNNER_CONFIG" "$installed_config"

    printf '%s\n' 'set -g @local-preserved yes' > "$installed_config"
    cp "$installed_config" "$preserved_config"
    assert_command_succeeds "second make install failed" \
        env XDG_CONFIG_HOME="$xdg_home" \
        make -C "$REPO_ROOT" HOME="$home" install
    install_after=$(date -u '+%s')
    assert_command_succeeds "second install changed the local config" \
        cmp -s "$preserved_config" "$installed_config"

    expected_hash=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
    if ! git -C "$REPO_ROOT" diff --quiet HEAD --; then
        expected_hash="${expected_hash}-dirty"
    fi
    commit_timestamp=$(git -C "$REPO_ROOT" show -s --format=%ct HEAD)
    expected_commit_date=$(
        date -u -d "@${commit_timestamp}" '+%Y-%m-%dT%H:%M:%SZ'
    )
    version_output=$(env PATH=/nonexistent /bin/bash \
        "$installed_runner" --version)
    assert_equal "tmux-runner version 0.1.0 (${expected_hash})" \
        "${version_output%%$'\n'*}" \
        "installed runner reported the wrong version or Git hash"
    assert_equal "$expected_commit_date" \
        "$(printf '%s\n' "$version_output" | sed -n 's/^commit date:  //p')" \
        "installed runner reported the wrong commit date"
    install_date=$(
        printf '%s\n' "$version_output" | sed -n 's/^install date: //p'
    )
    install_epoch=$(date -u -d "$install_date" '+%s')
    if (( install_epoch < install_before || install_epoch > install_after )); then
        fail_test "installed runner reported an out-of-range install date"
    fi

    run_tmux "$root" -f /dev/null new-session -d -s install-target
    run_outside_success t6-installed-attach "$root" "$home" "$xdg_home" \
        "$installed_runner" install-target attach -t install-target
    assert_session_entry_trace_with_prefix "$LAST_TRANSCRIPT" "$root" \
        install-target \
        "$TMUX_PATH -L $RUNNER_SERVER_NAME -f '$installed_config'" \
        "installed runner did not use the exact target"
    pass_test T6 \
        "isolated local installation, config preservation, and execution"
}

function test_t7_documentation {
    assert_contains "$README" "tmux-runner create" \
        "README omits create syntax"
    assert_contains "$README" "tmux-runner attach -t" \
        "README omits attach -t syntax"
    assert_contains "$README" "tmux-runner attach --" \
        "README omits attach terminator syntax"
    assert_contains "$README" "tmux-runner recent" \
        "README omits recent syntax"
    assert_contains "$README" "tmux-runner last" \
        "README omits last syntax"
    assert_contains "$README" "tmux-runner --help" \
        "README omits top-level help"
    assert_contains "$README" "tmux-runner --version" \
        "README omits version output"
    assert_contains "$README" "tmux-runner create --help" \
        "README omits command help"
    assert_contains "$README" "tmux-runner ls --help" \
        "README omits ls help"
    assert_contains "$README" "tmux-runner attach --help" \
        "README omits attach help"
    assert_contains "$README" "replaces \`.\` and \`:\` with \`_\`" \
        "README omits name normalization"
    assert_contains "$README" "exact-match \`=\` prefix" \
        "README omits exact target behavior"
    assert_contains "$README" "\`TMUX_TMPDIR\`" \
        "README omits outside UDS selection"
    assert_contains "$README" "tmux -L tmux-runner" \
        "README omits the dedicated server"
    assert_contains "$README" "switch-client\` inside" \
        "README omits inside client data flow"
    assert_contains "$README" "tmux \`#{session_id}\`" \
        "README omits transient session ID resolution"
    assert_contains "$README" "non-shell \`if-shell -F\`" \
        "README omits the server-side identity guard"
    assert_contains "$README" "raw marker value" \
        "README omits raw marker comparison"
    assert_contains "$README" "\`tmux-runner-unmarked\`" \
        "README omits reserved unmarked-session normalization"
    assert_contains "$README" "\`tmux-runner-global-unset\`" \
        "README omits the invalid global marker fallback"
    assert_contains "$README" "acknowledgment makes the runner fail" \
        "README omits failed acknowledgment behavior"
    assert_contains "$README" "ID and raw marker are not" \
        "README omits the unchanged state formats"
    assert_contains "$README" "acknowledgment-ticket formats" \
        "README omits the transaction state formats"
    assert_contains "$README" "detach and rerun" \
        "README omits the other-server boundary"
    assert_contains "$README" "tmux-runner/tmux.conf" \
        "README omits the local config path"
    assert_contains "$README" "take effect the next time" \
        "README omits config start-time behavior"
    assert_contains "$README" ".local/bin/tmux-runner" \
        "README omits runner install path"
    assert_contains "$README" \
        ".local/share/bash-completion/completions/tmux-runner" \
        "README omits completion install path"
    assert_contains "$README" "preserve the local file byte for byte" \
        "README omits config preservation"
    assert_contains "$README" "make install" \
        "README omits the install command"
    assert_contains "$README" "command -v bash" \
        "README omits the Bash requirement check"
    assert_contains "$README" "command -v tmux" \
        "README omits the tmux requirement check"
    assert_contains "$README" "command -v hostname" \
        "README omits the hostname requirement check"
    assert_contains "$README" "command -v make" \
        "README omits the Make requirement check"
    assert_contains "$README" "command -v install" \
        "README omits the install requirement check"
    assert_contains "$README" "command -v git" \
        "README omits the Git requirement check"
    assert_contains "$README" "command -v date" \
        "README omits the date requirement check"
    assert_contains "$README" "command -v sed" \
        "README omits the sed requirement check"
    assert_contains "$README" "command -v flock" \
        "README omits the flock requirement check"
    assert_contains "$README" "stamps an \`unknown\` hash" \
        "README omits no-Git installation identity"
    assert_contains "$README" \
        "installed copy never changes to live discovery" \
        "README omits immutable installed metadata"
    assert_contains "$README" "bash --version" \
        "README omits the Bash version check"
    assert_contains "$README" "make --version" \
        "README omits the Make version check"
    assert_contains "$README" "export PATH=\"\$HOME/.local/bin:\$PATH\"" \
        "README omits current-shell PATH preparation"
    assert_contains "$README" \
        'make HOME="/path/to/home" XDG_CONFIG_HOME="/path/to/home/.config" install' \
        "README test-home install command does not isolate both paths"
    assert_contains "$README" \
        'make -n HOME="/path/to/home" XDG_CONFIG_HOME="/path/to/home/.config" install' \
        "README test-home dry-run command does not isolate both paths"
    assert_contains "$README" "From the repository root" \
        "README omits the install working directory"
    assert_contains "$README" \
        "source ~/.local/share/bash-completion/completions/tmux-runner" \
        "README omits current-shell completion registration"
    assert_contains "$README" "cd /path/to/repository" \
        "README omits the first-use working directory"
    assert_contains "$README" "Ctrl-b" \
        "README omits the first-use detach sequence"
    assert_not_contains "$README" "systemd" \
        "README documents out-of-scope service management"
    pass_test T7 "shipped behavior and data-flow documentation"
}

function run_help_case {
    local label="$1"
    local expected_usage="$2"
    local stdout_file="$WORKSPACE/t8/$label.stdout"
    local stderr_file="$WORKSPACE/t8/$label.stderr"
    local rc=0

    shift 2
    env PATH=/nonexistent /bin/bash "$RUNNER" "$@" \
        > "$stdout_file" 2> "$stderr_file" || rc=$?
    assert_equal "0" "$rc" "$label help returned nonzero"
    if [[ -s "$stderr_file" ]]; then
        fail_test "$label help wrote to stderr"
    fi
    assert_contains "$stdout_file" "$expected_usage" \
        "$label help omitted its usage"
    assert_contains "$stdout_file" "-h, --help" \
        "$label help omitted its help options"
}

function test_t8_help {
    local rc=0
    local output_file="$WORKSPACE/t8/invalid.stdout"
    local error_file="$WORKSPACE/t8/invalid.stderr"

    mkdir -p -- "$WORKSPACE/t8"
    run_help_case top-short "Usage:" -h
    run_help_case top-long "Commands:" --help
    run_help_case create-short "Usage: tmux-runner create" create -h
    run_help_case create-long "Usage: tmux-runner create" create --help
    run_help_case c-short "Usage: tmux-runner c" c -h
    run_help_case c-long "Usage: tmux-runner c" c --help
    run_help_case repo-short "Usage: tmux-runner repo" repo -h
    run_help_case repo-long "Usage: tmux-runner repo" repo --help
    run_help_case recent-short "Usage: tmux-runner recent" recent -h
    run_help_case recent-long "Usage: tmux-runner recent" recent --help
    run_help_case last-short "Usage: tmux-runner last" last -h
    run_help_case last-long "Usage: tmux-runner last" last --help
    run_help_case list-short "Usage: tmux-runner ls" ls -h
    run_help_case list-long "Usage: tmux-runner ls" ls --help
    run_help_case attach-short "Usage: tmux-runner attach" attach -h
    run_help_case attach-long "Usage: tmux-runner attach" attach --help
    run_help_case a-short "Usage: tmux-runner a" a -h
    run_help_case a-long "Usage: tmux-runner a" a --help

    assert_contains "$WORKSPACE/t8/top-long.stdout" "create, c" \
        "top-level help omitted the create command summary"
    assert_contains "$WORKSPACE/t8/top-long.stdout" "repo" \
        "top-level help omitted the repo command summary"
    assert_contains "$WORKSPACE/t8/top-long.stdout" "recent" \
        "top-level help omitted the recent command summary"
    assert_contains "$WORKSPACE/t8/top-long.stdout" "last" \
        "top-level help omitted the last command summary"
    assert_contains "$WORKSPACE/t8/top-long.stdout" "attach, a" \
        "top-level help omitted the attach command summary"
    assert_contains "$WORKSPACE/t8/top-long.stdout" "-V, --version" \
        "top-level help omitted the version options"
    assert_contains "$WORKSPACE/t8/create-long.stdout" "-s <session-name>" \
        "create help omitted the session option"
    assert_contains "$WORKSPACE/t8/create-long.stdout" "-c <folder>" \
        "create help omitted the folder option"
    assert_contains "$WORKSPACE/t8/create-long.stdout" \
        "<repo-or-folder>-<short-hostname>" \
        "create help omitted the default session name"
    assert_contains "$WORKSPACE/t8/list-long.stdout" "select one by number" \
        "ls help omitted selection behavior"
    assert_contains "$WORKSPACE/t8/attach-long.stdout" \
        "-- <session-name>" \
        "attach help omitted the option terminator form"
    assert_contains "$WORKSPACE/t8/attach-long.stdout" \
        "exact name" \
        "attach help omitted exact-name behavior"

    env PATH=/nonexistent /bin/bash "$RUNNER" --help extra \
        > "$output_file" 2> "$error_file" || rc=$?
    assert_equal "2" "$rc" "help with an extra argument returned the wrong status"
    assert_contains "$error_file" "help does not accept arguments" \
        "help with an extra argument omitted its error"
    assert_not_contains "$error_file" "tmux is not available" \
        "help validated tmux before its own arguments"
    pass_test T8 "dependency-free top-level and command help"
}

function test_t9_version {
    local expected_hash=""
    local commit_timestamp=""
    local expected_commit_date=""
    local short_output=""
    local long_output=""
    local no_git_output=""
    local active_install_date=""
    local fixture_seed="$WORKSPACE/t9/seed"
    local seed_runner="$WORKSPACE/t9/seed/bin/tmux-runner"
    local clean_repository="$WORKSPACE/t9/relocated-clean"
    local clean_runner="$WORKSPACE/t9/relocated-clean/bin/tmux-runner"
    local modified_repository="$WORKSPACE/t9/relocated-modified"
    local modified_runner="$WORKSPACE/t9/relocated-modified/bin/tmux-runner"
    local locked_repository="$WORKSPACE/t9/relocated-locked"
    local locked_runner="$WORKSPACE/t9/relocated-locked/bin/tmux-runner"
    local fixture_hash=""
    local fixture_output=""
    local clean_installed="$WORKSPACE/t9/clean-install/tmux-runner"
    local dirty_installed="$WORKSPACE/t9/dirty-install/tmux-runner"
    local locked_installed="$WORKSPACE/t9/locked-install/tmux-runner"
    local missing_anchor="$WORKSPACE/t9/missing-anchor/tmux-runner"
    local duplicate_anchor="$WORKSPACE/t9/duplicate-anchor/tmux-runner"
    local stdout_file="$WORKSPACE/t9/invalid.stdout"
    local stderr_file="$WORKSPACE/t9/invalid.stderr"
    local ambient_repository="$WORKSPACE/t9/ambient-repository"
    local ambient_hash=""
    local ambient_output=""
    local rc=0

    mkdir -p -- "$WORKSPACE/t9/unrelated" "$fixture_seed/bin" \
        "${clean_installed%/*}" "${dirty_installed%/*}" \
        "${locked_installed%/*}" "${missing_anchor%/*}" \
        "${duplicate_anchor%/*}"
    init_git_repository "$ambient_repository"
    printf 'ambient\n' > "$ambient_repository/ambient.txt"
    git -C "$ambient_repository" add ambient.txt
    git -C "$ambient_repository" commit -q -m "Change ambient identity"
    ambient_hash=$(git -C "$ambient_repository" rev-parse --short HEAD)
    expected_hash=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
    if ! git -C "$REPO_ROOT" diff --quiet HEAD --; then
        expected_hash="${expected_hash}-dirty"
    fi
    commit_timestamp=$(git -C "$REPO_ROOT" show -s --format=%ct HEAD)
    expected_commit_date=$(
        date -u -d "@${commit_timestamp}" '+%Y-%m-%dT%H:%M:%SZ'
    )

    short_output=$(cd -- "$WORKSPACE/t9/unrelated" && "$RUNNER" -V)
    long_output=$(cd -- "$WORKSPACE/t9/unrelated" && "$RUNNER" --version)
    ambient_output=$(env GIT_DIR="$ambient_repository/.git" \
        GIT_WORK_TREE="$ambient_repository" "$RUNNER" --version)
    assert_equal "$short_output" "$long_output" \
        "short and long version forms differ"
    assert_equal "$long_output" "$ambient_output" \
        "ambient Git controls changed version repository identity"
    if [[ "$TEST_VARIANT" == "source" ]]; then
        assert_equal "tmux-runner version 0.1.0 (${expected_hash} (live))" \
            "${long_output%%$'\n'*}" \
            "source runner reported the wrong live version or Git hash"
    else
        assert_equal "tmux-runner version 0.1.0 (${expected_hash})" \
            "${long_output%%$'\n'*}" \
            "installed runner reported the wrong injected Git hash"
    fi
    assert_equal "$expected_commit_date" \
        "$(printf '%s\n' "$long_output" | sed -n 's/^commit date:  //p')" \
        "source runner reported the wrong live commit date"
    active_install_date=$(
        printf '%s\n' "$long_output" | sed -n 's/^install date: //p'
    )
    if [[ "$TEST_VARIANT" == "source" ]]; then
        assert_equal "live" "$active_install_date" \
            "source runner did not identify its live install state"
    elif ! date -u -d "$active_install_date" '+%s' >/dev/null 2>&1; then
        fail_test "installed runner reported an invalid install date"
    fi

    # Commit once, then copy without running Git in the copies. The relocated
    # files have new inodes while the copied index retains its cached stat
    # data, which distinguishes a content diff from an index-only verdict.
    cp "$SOURCE_RUNNER" "$seed_runner"
    git -C "$fixture_seed" init -q
    git -C "$fixture_seed" config core.hooksPath /dev/null
    git -C "$fixture_seed" add bin/tmux-runner
    git -C "$fixture_seed" -c user.name=tmux-runner-test \
        -c user.email=tmux-runner-test@example.invalid \
        commit -qm "Create version fixture"
    fixture_hash=$(git -C "$fixture_seed" rev-parse --short HEAD)
    assert_not_equal "$ambient_hash" "$fixture_hash" \
        "ambient and explicit injector repositories have the same identity"
    cp -a "$fixture_seed" "$clean_repository"
    cp -a "$fixture_seed" "$modified_repository"
    cp -a "$fixture_seed" "$locked_repository"
    printf '\n%s\n' '# Fixture modification.' >> "$modified_runner"
    chmod a-w "$locked_repository/.git" "$locked_repository/.git/index"

    fixture_output=$(cd -- "$WORKSPACE/t9/unrelated" && "$clean_runner" -V)
    assert_equal "tmux-runner version 0.1.0 (${fixture_hash} (live))" \
        "${fixture_output%%$'\n'*}" \
        "relocated clean fixture did not report a bare live Git hash"

    cp "$clean_runner" "$clean_installed"
    env GIT_DIR="$ambient_repository/.git" \
        GIT_WORK_TREE="$ambient_repository" \
        bash "$VERSION_INJECTOR" "$clean_installed" "$clean_repository"
    fixture_output=$(env PATH=/nonexistent /bin/bash \
        "$clean_installed" --version)
    assert_equal "tmux-runner version 0.1.0 (${fixture_hash})" \
        "${fixture_output%%$'\n'*}" \
        "relocated clean installation did not retain its Git hash"

    fixture_output=$(cd -- "$WORKSPACE/t9/unrelated" && "$modified_runner" -V)
    assert_equal \
        "tmux-runner version 0.1.0 (${fixture_hash}-dirty (live))" \
        "${fixture_output%%$'\n'*}" \
        "relocated modified fixture did not report a dirty live Git hash"

    cp "$modified_runner" "$dirty_installed"
    bash "$VERSION_INJECTOR" "$dirty_installed" "$modified_repository"
    fixture_output=$(env PATH=/nonexistent /bin/bash \
        "$dirty_installed" --version)
    assert_equal "tmux-runner version 0.1.0 (${fixture_hash}-dirty)" \
        "${fixture_output%%$'\n'*}" \
        "relocated modified installation did not retain its dirty Git hash"

    fixture_output=$(cd -- "$WORKSPACE/t9/unrelated" && "$locked_runner" -V)
    assert_equal "tmux-runner version 0.1.0 (${fixture_hash} (live))" \
        "${fixture_output%%$'\n'*}" \
        "read-only relocated index produced a dirty live Git hash"

    cp "$locked_runner" "$locked_installed"
    bash "$VERSION_INJECTOR" "$locked_installed" "$locked_repository"
    fixture_output=$(env PATH=/nonexistent /bin/bash \
        "$locked_installed" --version)
    assert_equal "tmux-runner version 0.1.0 (${fixture_hash})" \
        "${fixture_output%%$'\n'*}" \
        "read-only relocated index produced a dirty installed Git hash"

    no_git_output=$(
        env PATH=/nonexistent /bin/bash "$SOURCE_RUNNER" --version
    )
    assert_equal "tmux-runner version 0.1.0 (unknown)" \
        "${no_git_output%%$'\n'*}" \
        "dependency-free version output is wrong"
    assert_equal "unreleased" \
        "$(printf '%s\n' "$no_git_output" | sed -n 's/^commit date:  //p')" \
        "dependency-free version commit date is wrong"
    assert_equal "unreleased" \
        "$(printf '%s\n' "$no_git_output" | sed -n 's/^install date: //p')" \
        "dependency-free install date is wrong"

    sed '/^readonly RUNNER_GIT_HASH=/d' \
        "$SOURCE_RUNNER" > "$missing_anchor"
    rc=0
    bash "$VERSION_INJECTOR" "$missing_anchor" "$clean_repository" \
        > "$stdout_file" 2> "$stderr_file" || rc=$?
    assert_equal "2" "$rc" \
        "injector accepted a missing metadata declaration"
    assert_contains "$stderr_file" \
        "expected exactly one readonly RUNNER_GIT_HASH declaration" \
        "missing metadata declaration error is unclear"

    cp "$SOURCE_RUNNER" "$duplicate_anchor"
    printf '%s\n' 'readonly RUNNER_GIT_HASH="duplicate"' >> "$duplicate_anchor"
    rc=0
    bash "$VERSION_INJECTOR" "$duplicate_anchor" "$clean_repository" \
        > "$stdout_file" 2> "$stderr_file" || rc=$?
    assert_equal "2" "$rc" \
        "injector accepted duplicate metadata declarations"
    assert_contains "$stderr_file" \
        "expected exactly one readonly RUNNER_GIT_HASH declaration" \
        "duplicate metadata declaration error is unclear"

    rc=0
    env PATH=/nonexistent /bin/bash "$RUNNER" --version extra \
        > "$stdout_file" 2> "$stderr_file" || rc=$?
    assert_equal "2" "$rc" \
        "version with an extra argument returned the wrong status"
    assert_contains "$stderr_file" "version does not accept arguments" \
        "version with an extra argument omitted its error"
    assert_not_contains "$stderr_file" "tmux is not available" \
        "version validated tmux before its own arguments"
    pass_test T9 "$TEST_VARIANT and fixture version metadata"
}

function test_server_command_path {
    local runner_tmux_calls=0

    # These patterns inspect literal variable references in the shipped code.
    # shellcheck disable=SC2016
    runner_tmux_calls=$(grep -Ec '^[[:space:]]*"\$TMUX_BIN"' "$RUNNER")
    assert_equal "1" "$runner_tmux_calls" \
        "runner has a tmux invocation outside the centralized wrapper"
    # shellcheck disable=SC2016
    assert_contains "$RUNNER" \
        '"$TMUX_BIN" -L "$TMUX_SERVER_NAME" -f "$config_file"' \
        "runner tmux wrapper omits the named server or config"
    assert_contains "$COMPLETION" "tmux -L tmux-runner -f" \
        "completion does not use the dedicated server"
    assert_contains "$RUNNER_CONFIG" \
        "Local configuration for the tmux-runner server." \
        "starter config is not the shipped no-op file"
    pass_test SERVER-COMMAND-PATH "centralized dedicated-server path"
}

function test_server_isolation {
    local root=""
    local home=""
    local xdg_home=""
    local list_output="$WORKSPACE/server-isolation/list.out"
    local list_error="$WORKSPACE/server-isolation/list.err"
    local completion_output=""
    local default_before=""
    local rc=0

    create_tmux_root server-isolation
    root="$NEW_TMUX_ROOT"
    home="$WORKSPACE/server-isolation/home"
    xdg_home="$WORKSPACE/server-isolation/xdg"
    mkdir -p -- "$home" "$xdg_home"
    run_default_tmux "$root" -f /dev/null new-session -d -s default-only
    run_tmux "$root" -f /dev/null new-session -d -s runner-only
    default_before=$(one_server_snapshot "$root" default)

    env -u TMUX HOME="$home" XDG_CONFIG_HOME="$xdg_home" \
        TMUX_TMPDIR="$root" bash "$RUNNER" ls \
        > "$list_output" 2> "$list_error" <<< "invalid" || rc=$?
    assert_equal "2" "$rc" "dedicated ls invalid selection returned wrong status"
    assert_contains "$list_output" "runner-only:" \
        "dedicated ls omitted its session"
    assert_not_contains "$list_output" "default-only:" \
        "dedicated ls exposed a default-server session"

    # Positional parameters are expanded by the completion subprocess.
    # shellcheck disable=SC2016
    completion_output=$(env HOME="$home" XDG_CONFIG_HOME="$xdg_home" \
        TMUX_TMPDIR="$root" bash -c \
        'source "$1"; COMP_WORDS=(tmux-runner attach ""); COMP_CWORD=2; _tmux_runner; printf "%s\n" "${COMPREPLY[@]}"' \
        bash "$COMPLETION")
    assert_contains <(printf '%s\n' "$completion_output") "runner-only" \
        "completion omitted the dedicated session"
    if grep -Fx -- "default-only" <<< "$completion_output" >/dev/null; then
        fail_test "completion exposed a default-server session"
    fi

    run_outside_success server-isolation-attach "$root" "$home" "$xdg_home" \
        "$RUNNER" runner-only attach runner-only
    run_outside_success server-isolation-create "$root" "$home" "$xdg_home" \
        "$RUNNER" runner-created create -s runner-created -c "$home"
    assert_equal "$default_before" "$(one_server_snapshot "$root" default)" \
        "runner operations changed the default server"
    assert_session_set "$root" "dedicated session set is wrong" \
        runner-only runner-created
    assert_equal "default-only" \
        "$(run_default_tmux "$root" list-sessions -F '#{session_name}')" \
        "default server session set changed"
    pass_test SERVER-ISOLATION "create, list, attach, and completion server isolation"
}

function test_server_config_lifecycle {
    local root=""
    local home=""
    local xdg_home=""
    local config_file=""
    local default_before=""
    local marker=""
    local binding=""

    create_tmux_root server-config
    root="$NEW_TMUX_ROOT"
    home="$WORKSPACE/server-config/home"
    xdg_home="$WORKSPACE/server-config/xdg"
    config_file="$xdg_home/tmux-runner/tmux.conf"
    mkdir -p -- "$home" "${config_file%/*}"
    printf '%s\n' 'set -g @general-marker general' > "$home/.tmux.conf"
    env -u TMUX HOME="$home" TMUX_TMPDIR="$root" \
        tmux -f "$home/.tmux.conf" new-session -d -s default-config
    assert_equal "general" \
        "$(run_default_tmux "$root" show-options -gv @general-marker)" \
        "default server did not load its general marker"
    default_before=$(one_server_snapshot "$root" default)

    run_outside_success server-config-absent "$root" "$home" "$xdg_home" \
        "$RUNNER" isolated create -s isolated -c "$home"
    marker=$(run_tmux "$root" show-options -gv @general-marker 2>/dev/null || true)
    assert_equal "" "$marker" \
        "absent runner config allowed the general tmux config"
    run_tmux "$root" kill-server

    cp "$RUNNER_CONFIG" "$config_file"
    run_outside_success server-config-starter "$root" "$home" "$xdg_home" \
        "$RUNNER" starter create -s starter -c "$home"
    run_tmux "$root" kill-server

    {
        printf '%s\n' 'set -g @runner-marker one'
        printf '%s\n' 'set -g status off'
        printf '%s\n' 'bind-key C-r display-message runner-one'
    } > "$config_file"
    run_outside_success server-config-first "$root" "$home" "$xdg_home" \
        "$RUNNER" configured create -s configured -c "$home"
    assert_equal "one" "$(run_tmux "$root" show-options -gv @runner-marker)" \
        "runner config marker did not load"
    assert_equal "off" "$(run_tmux "$root" show-options -gv status)" \
        "runner config status option did not load"
    binding=$(run_tmux "$root" list-keys -T prefix C-r)
    if ! grep -F -- "runner-one" <<< "$binding" >/dev/null; then
        fail_test "runner config key binding did not load"
    fi

    {
        printf '%s\n' 'set -g @runner-marker two'
        printf '%s\n' 'set -g status on'
        printf '%s\n' 'bind-key C-r display-message runner-two'
    } > "$config_file"
    run_outside_success server-config-running "$root" "$home" "$xdg_home" \
        "$RUNNER" configured attach configured
    assert_equal "one" "$(run_tmux "$root" show-options -gv @runner-marker)" \
        "running server reloaded its config"
    assert_equal "off" "$(run_tmux "$root" show-options -gv status)" \
        "running server changed its status option"

    run_tmux "$root" kill-server
    run_outside_success server-config-restart "$root" "$home" "$xdg_home" \
        "$RUNNER" configured-again create -s configured-again -c "$home"
    assert_equal "two" "$(run_tmux "$root" show-options -gv @runner-marker)" \
        "restarted server did not reload its config"
    assert_equal "on" "$(run_tmux "$root" show-options -gv status)" \
        "restarted server did not reload its status option"
    binding=$(run_tmux "$root" list-keys -T prefix C-r)
    if ! grep -F -- "runner-two" <<< "$binding" >/dev/null; then
        fail_test "restarted server did not reload its key binding"
    fi
    assert_equal "$default_before" "$(one_server_snapshot "$root" default)" \
        "runner config lifecycle changed the default server"
    pass_test SERVER-CONFIG-LIFECYCLE "isolated first-start config and dedicated-only reload"
}

function test_server_client_boundary {
    local root=""
    local home=""
    local xdg_home=""
    local source_session="default-client"
    local status=""
    local runner_socket=""

    create_tmux_root server-client
    root="$NEW_TMUX_ROOT"
    home="$WORKSPACE/server-client/home"
    xdg_home="$WORKSPACE/server-client/xdg"
    mkdir -p -- "$home" "$xdg_home"
    runner_socket="$root/tmux-$UID/$RUNNER_SERVER_NAME"
    run_default_tmux "$root" -f /dev/null new-session -d -s "$source_session"
    start_default_source_client server-client "$root" "$home" "$xdg_home" \
        "$source_session"
    if [[ -e "$runner_socket" ]]; then
        fail_test "client-boundary fixture started the dedicated socket early"
    fi

    start_dual_state_monitor server-client "$root"
    invoke_runner_inside_default server-client-reject "$root" "$home" "$xdg_home" \
        "$source_session" "$RUNNER" create -s forbidden -c "$home"
    if ! wait_for_file "$LAST_INSIDE_STATUS"; then
        fail_test "other-server rejection did not record status"
    fi
    status=$(inside_runner_status)
    assert_not_equal "0" "$status" \
        "runner accepted a client from another server"
    assert_contains "$LAST_INSIDE_TRACE" \
        "detach and rerun tmux-runner from the outer shell" \
        "other-server rejection omitted detach guidance"
    stop_state_monitor server-client
    if [[ -e "$runner_socket" ]]; then
        fail_test "other-server rejection created the dedicated socket"
    fi

    invoke_runner_inside_default server-client-help "$root" "$home" "$xdg_home" \
        "$source_session" "$RUNNER" --help
    if ! wait_for_file "$LAST_INSIDE_STATUS"; then
        fail_test "help inside another server did not record status"
    fi
    assert_equal "0" "$(inside_runner_status)" \
        "help inside another server failed"
    assert_contains "$LAST_INSIDE_TRACE" "Session commands use the dedicated" \
        "help omitted the dedicated-server contract"

    invoke_runner_inside_default server-client-version "$root" "$home" "$xdg_home" \
        "$source_session" "$RUNNER" --version
    if ! wait_for_file "$LAST_INSIDE_STATUS"; then
        fail_test "version inside another server did not record status"
    fi
    assert_equal "0" "$(inside_runner_status)" \
        "version inside another server failed"
    if [[ -e "$runner_socket" ]]; then
        fail_test "dependency-free commands created the dedicated socket"
    fi
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "default source client failed"
    pass_test SERVER-CLIENT-BOUNDARY "dedicated switching and cold other-server rejection"
}

function test_identity_repository {
    local root=""
    local ambient_root=""
    local home="$WORKSPACE/identity-repository/home"
    local xdg_home="$WORKSPACE/identity-repository/xdg"
    local repository="$WORKSPACE/identity-repository/project.repo"
    local ambient_repository="$WORKSPACE/identity-repository/ambient.repo"
    local subdir_one="$repository/src/one"
    local subdir_two="$repository/src/two"
    local short_hostname=""
    local session_name=""
    local identity_before=""

    create_tmux_root identity-repository
    root="$NEW_TMUX_ROOT"
    mkdir -p -- "$home" "$xdg_home"
    init_git_repository "$repository"
    init_git_repository "$ambient_repository"
    mkdir -p -- "$subdir_one" "$subdir_two"
    short_hostname=$(hostname -s)
    short_hostname="${short_hostname//./_}"
    short_hostname="${short_hostname//:/_}"
    session_name="project_repo-$short_hostname"

    run_outside_success identity-repository-first "$root" "$home" "$xdg_home" \
        "$RUNNER" "$session_name" create -c "$subdir_one"
    assert_equal "$repository" "$(session_path "$root" "$session_name")" \
        "repository session recorded the wrong canonical path"
    assert_equal "$repository" "$(pane_directory "$root" "$session_name")" \
        "repository session did not start at the Git top level"
    identity_before=$(session_identity "$root" "$session_name")

    run_outside_success identity-repository-second "$root" "$home" "$xdg_home" \
        "$RUNNER" "$session_name" create -c "$subdir_two"
    assert_equal "$identity_before" \
        "$(session_identity "$root" "$session_name")" \
        "two repository subdirectories did not reuse one session"
    assert_not_contains "$LAST_TRANSCRIPT" \
        "$TMUX_RUNNER_TRACE_PREFIX new-session" \
        "repository path reuse created another session"

    create_tmux_root identity-repository-ambient
    ambient_root="$NEW_TMUX_ROOT"
    start_pty_command identity-repository-ambient "$ambient_root" "$home" "$xdg_home" \
        env GIT_DIR="$ambient_repository/.git" \
        GIT_WORK_TREE="$ambient_repository" bash -x "$RUNNER" \
        create -c "$subdir_one"
    if ! wait_for_client_session "$ambient_root" "$session_name"; then
        fail_test "ambient Git create did not reach $session_name"
    fi
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "ambient Git create failed"
    assert_equal "$repository" \
        "$(session_path "$ambient_root" "$session_name")" \
        "ambient Git controls changed create folder identity"
    pass_test IDENTITY-REPOSITORY "Git top-level path identity and subdirectory reuse"
}

function test_identity_collision {
    local root=""
    local home="$WORKSPACE/identity-collision/home"
    local xdg_home="$WORKSPACE/identity-collision/xdg"
    local short_hostname=""
    local repo_one="$WORKSPACE/identity-collision/base-one/shared"
    local repo_two="$WORKSPACE/identity-collision/base-two/shared"
    local deep_one="$WORKSPACE/identity-collision/top-one/common/deep"
    local deep_two="$WORKSPACE/identity-collision/top-two/common/deep"
    local triple_one="$WORKSPACE/identity-collision/head-one/same/middle/triple"
    local triple_two="$WORKSPACE/identity-collision/head-two/same/middle/triple"
    local norm_one="$WORKSPACE/identity-collision/hash/alpha.dot/norm"
    local norm_two="$WORKSPACE/identity-collision/hash/alpha:dot/norm"
    local race_one="$WORKSPACE/identity-collision/race-one/race"
    local race_two="$WORKSPACE/identity-collision/race-two/race"
    local hash_output=""
    local path_hash=""
    local full_stem=""
    local occupied_name=""
    local hash_name=""
    local unrelated_path="$WORKSPACE/identity-collision/unrelated"

    create_tmux_root identity-collision
    root="$NEW_TMUX_ROOT"
    mkdir -p -- "$home" "$xdg_home" "$unrelated_path"
    init_git_repository "$repo_one"
    init_git_repository "$repo_two"
    init_git_repository "$deep_one"
    init_git_repository "$deep_two"
    init_git_repository "$triple_one"
    init_git_repository "$triple_two"
    init_git_repository "$norm_one"
    init_git_repository "$norm_two"
    init_git_repository "$race_one"
    init_git_repository "$race_two"
    short_hostname=$(hostname -s)
    short_hostname="${short_hostname//./_}"
    short_hostname="${short_hostname//:/_}"

    run_outside_success identity-collision-base-one "$root" "$home" "$xdg_home" \
        "$RUNNER" "shared-$short_hostname" create -c "$repo_one"
    run_outside_success identity-collision-base-two "$root" "$home" "$xdg_home" \
        "$RUNNER" "base-two-shared-$short_hostname" create -c "$repo_two"
    assert_equal "$repo_one" \
        "$(session_path "$root" "shared-$short_hostname")" \
        "first same-basename repository path changed"
    assert_equal "$repo_two" \
        "$(session_path "$root" "base-two-shared-$short_hostname")" \
        "one-parent collision name recorded the wrong path"

    run_outside_success identity-collision-deep-one "$root" "$home" "$xdg_home" \
        "$RUNNER" "deep-$short_hostname" create -c "$deep_one"
    run_outside_success identity-collision-deep-two "$root" "$home" "$xdg_home" \
        "$RUNNER" "top-two-common-deep-$short_hostname" create -c "$deep_two"
    run_outside_success identity-collision-triple-one "$root" "$home" "$xdg_home" \
        "$RUNNER" "triple-$short_hostname" create -c "$triple_one"
    run_outside_success identity-collision-triple-two "$root" "$home" "$xdg_home" \
        "$RUNNER" "head-two-same-middle-triple-$short_hostname" create \
        -c "$triple_two"

    run_outside_success identity-collision-norm-one "$root" "$home" "$xdg_home" \
        "$RUNNER" "norm-$short_hostname" create -c "$norm_one"
    hash_output=$(printf '%s' "$norm_two" | sha256sum)
    path_hash="${hash_output%% *}"
    full_stem="${norm_two#/}"
    full_stem="${full_stem//\//-}"
    full_stem="${full_stem//./_}"
    full_stem="${full_stem//:/_}"
    occupied_name="${full_stem}-${path_hash:0:12}-$short_hostname"
    hash_name="${full_stem}-${path_hash:0:13}-$short_hostname"
    run_tmux "$root" new-session -d -s "$occupied_name" -c "$unrelated_path"
    run_tmux "$root" set-option -t "=$occupied_name:" \
        @tmux-runner-path "$unrelated_path"
    run_outside_success identity-collision-norm-two "$root" "$home" "$xdg_home" \
        "$RUNNER" "$hash_name" create -c "$norm_two"
    assert_equal "$norm_two" "$(session_path "$root" "$hash_name")" \
        "normalized collision did not extend the occupied hash prefix"
    assert_equal "$unrelated_path" \
        "$(session_path "$root" "$occupied_name")" \
        "hash collision handling changed the occupied session marker"

    run_concurrent_auto_create identity-collision-race "$root" "$home" "$xdg_home" \
        "$RUNNER" "$race_one" "$race_two"
    assert_equal "1" \
        "$(session_name_for_path "$root" "$race_one" | grep -c .)" \
        "concurrent first path did not keep one session"
    assert_equal "1" \
        "$(session_name_for_path "$root" "$race_two" | grep -c .)" \
        "concurrent second path did not keep one session"
    pass_test IDENTITY-COLLISION "minimum-parent, hash-extension, and concurrent identity"
}

function test_identity_worktree {
    local root=""
    local home="$WORKSPACE/identity-worktree/home"
    local xdg_home="$WORKSPACE/identity-worktree/xdg"
    local main_repo="$WORKSPACE/identity-worktree/main-repo"
    local linked_repo="$WORKSPACE/identity-worktree/linked-repo"
    local short_hostname=""
    local main_name=""
    local linked_name=""

    create_tmux_root identity-worktree
    root="$NEW_TMUX_ROOT"
    mkdir -p -- "$home" "$xdg_home"
    init_git_repository "$main_repo"
    git -C "$main_repo" worktree add -q -b linked-fixture "$linked_repo"
    short_hostname=$(hostname -s)
    short_hostname="${short_hostname//./_}"
    short_hostname="${short_hostname//:/_}"
    main_name="main-repo-$short_hostname"
    linked_name="linked-repo-$short_hostname"

    run_outside_success identity-worktree-main "$root" "$home" "$xdg_home" \
        "$RUNNER" "$main_name" create -c "$main_repo"
    run_outside_success identity-worktree-linked "$root" "$home" "$xdg_home" \
        "$RUNNER" "$linked_name" create -c "$linked_repo"
    assert_not_equal "$(session_identity "$root" "$main_name")" \
        "$(session_identity "$root" "$linked_name")" \
        "main and linked working trees shared one session identity"
    assert_equal "$main_repo" "$(session_path "$root" "$main_name")" \
        "main working tree recorded the wrong path"
    assert_equal "$linked_repo" "$(session_path "$root" "$linked_name")" \
        "linked working tree recorded the wrong path"
    assert_equal "$linked_repo" "$(pane_directory "$root" "$linked_name")" \
        "linked working tree session started in the wrong path"
    pass_test IDENTITY-WORKTREE "real linked-worktree identity"
}

function test_identity_explicit {
    local root=""
    local home="$WORKSPACE/identity-explicit/home"
    local xdg_home="$WORKSPACE/identity-explicit/xdg"
    local physical_dir="$WORKSPACE/identity-explicit/physical-folder"
    local alias_dir="$WORKSPACE/identity-explicit/folder-alias"
    local repository="$WORKSPACE/identity-explicit/explicit-repo"
    local single_repo="$WORKSPACE/identity-explicit/single-repo"
    local other_path="$WORKSPACE/identity-explicit/other-path"
    local short_hostname=""
    local physical_name=""
    local identity_before=""
    local fingerprint_before=""

    create_tmux_root identity-explicit
    root="$NEW_TMUX_ROOT"
    mkdir -p -- "$home" "$xdg_home" "$physical_dir" "$other_path"
    ln -s -- "$physical_dir" "$alias_dir"
    init_git_repository "$repository"
    init_git_repository "$single_repo"
    short_hostname=$(hostname -s)
    short_hostname="${short_hostname//./_}"
    short_hostname="${short_hostname//:/_}"
    physical_name="physical-folder-$short_hostname"

    run_outside_success identity-explicit-physical "$root" "$home" "$xdg_home" \
        "$RUNNER" "$physical_name" create -c "$physical_dir"
    identity_before=$(session_identity "$root" "$physical_name")
    run_outside_success identity-explicit-alias "$root" "$home" "$xdg_home" \
        "$RUNNER" "$physical_name" create -c "$alias_dir"
    assert_equal "$identity_before" \
        "$(session_identity "$root" "$physical_name")" \
        "symlink path did not reuse the physical directory identity"

    run_outside_success identity-explicit-explicit-one "$root" "$home" "$xdg_home" \
        "$RUNNER" explicit-one create -s explicit-one -c "$repository"
    run_outside_success identity-explicit-explicit-two "$root" "$home" "$xdg_home" \
        "$RUNNER" explicit-two create -s explicit-two -c "$repository"
    fingerprint_before=$(server_fingerprint "$root")
    run_outside_failure identity-explicit-ambiguous "$root" "$home" "$xdg_home" \
        "$RUNNER" create -c "$repository"
    assert_contains "$LAST_TRANSCRIPT" "multiple sessions match path" \
        "ambiguous automatic lookup omitted its error"
    assert_contains "$LAST_TRANSCRIPT" "  explicit-one" \
        "ambiguous automatic lookup omitted explicit-one"
    assert_contains "$LAST_TRANSCRIPT" "  explicit-two" \
        "ambiguous automatic lookup omitted explicit-two"
    assert_equal "$fingerprint_before" "$(server_fingerprint "$root")" \
        "ambiguous automatic lookup changed tmux state"

    run_outside_success identity-explicit-single-explicit "$root" "$home" "$xdg_home" \
        "$RUNNER" chosen-name create -s chosen-name -c "$single_repo"
    run_outside_success identity-explicit-single-auto "$root" "$home" "$xdg_home" \
        "$RUNNER" chosen-name create -c "$single_repo"
    assert_not_contains "$LAST_TRANSCRIPT" \
        "$TMUX_RUNNER_TRACE_PREFIX new-session" \
        "automatic lookup ignored one exact path match"

    run_tmux "$root" new-session -d -s unmarked-name -c "$other_path"
    run_outside_failure identity-explicit-unmarked "$root" "$home" "$xdg_home" \
        "$RUNNER" create -s unmarked-name -c "$repository"
    assert_contains "$LAST_TRANSCRIPT" \
        "exists without @tmux-runner-path" \
        "unmarked explicit conflict omitted its guidance"

    run_tmux "$root" new-session -d -s mismatched-name -c "$other_path"
    run_tmux "$root" set-option -t '=mismatched-name:' \
        @tmux-runner-path "$other_path"
    run_outside_failure identity-explicit-mismatch "$root" "$home" "$xdg_home" \
        "$RUNNER" create -s mismatched-name -c "$repository"
    assert_contains "$LAST_TRANSCRIPT" "belongs to $other_path" \
        "mismatched explicit conflict omitted the recorded path"
    assert_equal "$other_path" \
        "$(session_path "$root" mismatched-name)" \
        "mismatched explicit conflict changed the recorded path"
    pass_test IDENTITY-EXPLICIT "physical paths, path-first reuse, and explicit conflicts"
}

function test_identity_regression {
    assert_contains "$README" "@tmux-runner-path" \
        "README omits the canonical session path marker"
    assert_contains "$README" "main working tree" \
        "README omits linked-worktree identity"
    assert_contains "$README" "minimum distinguishing parent components" \
        "README omits automatic collision naming"
    assert_contains "$README" "Multiple explicit names" \
        "README omits explicit-name path behavior"
    assert_contains "$WORKSPACE/t8/create-long.stdout" \
        "Automatic names reuse one exact @tmux-runner-path match" \
        "create help omits path-first automatic reuse"
    assert_contains "$WORKSPACE/t8/create-long.stdout" \
        "Name collisions add minimum parent components, then a path hash." \
        "create help omits collision naming"
    assert_contains "$WORKSPACE/t8/create-long.stdout" \
        "an explicit name; multiple matches fail and list their names." \
        "create help omits explicit-name path reuse"
    assert_contains "$WORKSPACE/t8/create-long.stdout" \
        "Explicit -s names fail if occupied by another or unmarked path." \
        "create help omits explicit-name conflict behavior"
    pass_test IDENTITY-REGRESSION "core-through-identity command, install, server, and identity integration"
}

function test_catalog_configuration {
    local root=""
    local home="$WORKSPACE/catalog-configuration/home"
    local xdg_home="$WORKSPACE/catalog-configuration/xdg"
    local repos_file="$xdg_home/tmux-runner/repos"
    local literal_root="$WORKSPACE/catalog-configuration/catalog \$value *"
    local repository="$literal_root/repository with space"
    local command_root=""
    local command_repository=""
    local alias_root="$WORKSPACE/catalog-configuration/catalog-alias"
    local missing_root="$WORKSPACE/catalog-configuration/missing-root"
    local unreadable_root="$WORKSPACE/catalog-configuration/unreadable-root"
    local sentinel="$WORKSPACE/catalog-configuration/shell-evaluated"
    local fingerprint_before=""

    create_tmux_root catalog-configuration
    root="$NEW_TMUX_ROOT"
    mkdir -p -- "$home" "$xdg_home" "$literal_root" "$unreadable_root"
    run_tmux "$root" -f /dev/null new-session -d -s configuration-sentinel
    fingerprint_before=$(server_fingerprint "$root")

    run_outside_failure catalog-configuration-missing "$root" "$home" "$xdg_home" \
        "$RUNNER" repo
    assert_contains "$LAST_TRANSCRIPT" "$repos_file" \
        "missing repos guidance omitted the expected path"
    assert_contains "$LAST_TRANSCRIPT" \
        "Add one literal absolute search root per line." \
        "missing repos guidance omitted the setup form"

    mkdir -p -- "${repos_file%/*}"
    : > "$repos_file"
    run_outside_failure catalog-configuration-empty "$root" "$home" "$xdg_home" \
        "$RUNNER" repo
    assert_contains "$LAST_TRANSCRIPT" "has no usable roots" \
        "empty repos file omitted its error"

    init_git_repository "$repository"
    command_root="$WORKSPACE/catalog-configuration/catalog \$(touch\${IFS}\$CATALOG_SENTINEL)"
    command_repository="$command_root/command repository"
    init_git_repository "$command_repository"
    ln -s -- "$literal_root" "$alias_root"
    chmod 000 "$unreadable_root"
    {
        printf '\n'
        printf '   # ignored comment\n'
        printf '%s\n' "$literal_root"
        printf '%s\n' "$command_root"
        printf '%s\n' "$alias_root"
        printf '%s\n' "$literal_root"
        printf '%s\n' "$missing_root"
        printf '%s\n' "$unreadable_root"
        # The config must retain this literal tilde.
        # shellcheck disable=SC2088
        printf '%s\n' '~/not-expanded'
        printf '$%s\n' "(touch $sentinel)"
    } > "$repos_file"

    export CATALOG_SENTINEL="$sentinel"
    start_state_monitor catalog-configuration-literal "$root"
    start_runner_outside catalog-configuration-literal "$root" "$home" "$xdg_home" \
        "$RUNNER" repo
    if ! wait_for_transcript_text "Select repository:"; then
        fail_test "literal repository config did not reach its prompt"
    fi
    assert_repository_row_count "$LAST_TRANSCRIPT" "$repository" 1
    assert_repository_row_count "$LAST_TRANSCRIPT" "$command_repository" 1
    assert_contains "$LAST_TRANSCRIPT" \
        "repository root is missing: $missing_root" \
        "missing root warning was not displayed"
    assert_contains "$LAST_TRANSCRIPT" \
        "repository root is not accessible: $unreadable_root" \
        "unreadable root warning was not displayed"
    assert_contains "$LAST_TRANSCRIPT" \
        "repository root is not absolute: ~/not-expanded" \
        "tilde root was expanded or accepted"
    if [[ -e "$sentinel" ]]; then
        fail_test "repository config executed command substitution text"
    fi
    send_current_input 'not-a-number\n'
    finish_current_pty
    stop_state_monitor catalog-configuration-literal
    unset CATALOG_SENTINEL
    chmod 0700 "$unreadable_root"
    assert_last_pty_failed_without_timeout \
        "literal repository config invalid selection"
    assert_equal "$fingerprint_before" "$(server_fingerprint "$root")" \
        "repository configuration failures changed tmux state"
    pass_test CATALOG-CONFIGURATION "literal repository roots and no-state failure handling"
}

function test_catalog_discovery {
    local root=""
    local first_order_root=""
    local second_order_root=""
    local home="$WORKSPACE/catalog-discovery/home"
    local xdg_home="$WORKSPACE/catalog-discovery/xdg"
    local repos_file="$xdg_home/tmux-runner/repos"
    local root_repo="$WORKSPACE/catalog-discovery/root-repo"
    local scan_root="$WORKSPACE/catalog-discovery/scan-root"
    local nested_repo="$scan_root/outer/nested-repo"
    local source_repo="$scan_root/source-repo"
    local linked_repo="$scan_root/linked-repo"
    local bare_repo="$scan_root/bare-repo.git"
    local ordinary_dir="$scan_root/ordinary-directory"
    local shared_one="$scan_root/team-a/shared"
    local shared_two="$scan_root/team-b/shared"
    local norm_one="$scan_root/hash/alpha.dot/norm"
    local norm_two="$scan_root/hash/alpha:dot/norm"
    local newline_repo="$scan_root/newline"$'\n'"repository"
    local unreadable_subtree="$scan_root/unreadable-subtree"
    local hidden_repo="$unreadable_subtree/hidden-repo"
    local alias_root="$WORKSPACE/catalog-discovery/scan-alias"
    local rows_one=""
    local rows_two=""
    local stem_one=""
    local stem_two=""
    local hash_output=""
    local hash_one=""
    local hash_two=""
    local short_hostname=""
    local norm_one_name=""
    local norm_two_name=""

    create_tmux_root catalog-discovery
    root="$NEW_TMUX_ROOT"
    mkdir -p -- "$home" "${repos_file%/*}" "$scan_root" "$ordinary_dir"
    init_git_repository "$root_repo"
    init_git_repository "$nested_repo"
    init_git_repository "$source_repo"
    git -C "$source_repo" worktree add -q -b linked-catalog "$linked_repo"
    git init -q --bare "$bare_repo"
    git -C "$bare_repo" config core.hooksPath /dev/null
    init_git_repository "$shared_one"
    init_git_repository "$shared_two"
    init_git_repository "$norm_one"
    init_git_repository "$norm_two"
    init_git_repository "$newline_repo"
    init_git_repository "$hidden_repo"
    chmod 000 "$unreadable_subtree"
    ln -s -- "$scan_root" "$alias_root"
    ln -s -- "$scan_root" "$scan_root/loop"
    {
        printf '%s\n' "$root_repo"
        printf '%s\n' "$scan_root"
        printf '%s\n' "$scan_root/outer"
        printf '%s\n' "$alias_root"
    } > "$repos_file"
    run_tmux "$root" -f /dev/null new-session -d -s discovery-sentinel

    start_state_monitor catalog-discovery-first "$root"
    start_runner_outside catalog-discovery-first "$root" "$home" "$xdg_home" \
        "$RUNNER" repo
    if ! wait_for_transcript_text "Select repository:"; then
        fail_test "first repository discovery did not reach its prompt"
    fi
    rows_one=$(repository_rows "$LAST_TRANSCRIPT")
    assert_repository_row_count "$LAST_TRANSCRIPT" "$root_repo" 1
    assert_repository_row_count "$LAST_TRANSCRIPT" "$nested_repo" 1
    assert_repository_row_count "$LAST_TRANSCRIPT" "$source_repo" 1
    assert_repository_row_count "$LAST_TRANSCRIPT" "$linked_repo" 1
    assert_repository_row_count "$LAST_TRANSCRIPT" "$shared_one" 1
    assert_repository_row_count "$LAST_TRANSCRIPT" "$shared_two" 1
    assert_repository_row_count "$LAST_TRANSCRIPT" "$norm_one" 1
    assert_repository_row_count "$LAST_TRANSCRIPT" "$norm_two" 1
    assert_repository_row_count "$LAST_TRANSCRIPT" "$newline_repo" 0
    assert_repository_row_count "$LAST_TRANSCRIPT" "$hidden_repo" 0
    assert_repository_row_count "$LAST_TRANSCRIPT" "$bare_repo" 0
    assert_repository_row_count "$LAST_TRANSCRIPT" "$ordinary_dir" 0
    assert_contains "$LAST_TRANSCRIPT" "team-a-shared  $shared_one" \
        "first duplicate repository label is not minimum-parent"
    assert_contains "$LAST_TRANSCRIPT" "team-b-shared  $shared_two" \
        "second duplicate repository label is not minimum-parent"
    assert_contains "$LAST_TRANSCRIPT" "$unreadable_subtree" \
        "unreadable child warning omitted its path"
    assert_contains "$LAST_TRANSCRIPT" \
        "repository path contains a newline: $(encode_state_field \
            "$newline_repo")" \
        "newline repository warning omitted its encoded path"

    stem_one="${norm_one#/}"
    stem_one="${stem_one//\//-}"
    stem_one="${stem_one//./_}"
    stem_one="${stem_one//:/_}"
    stem_two="${norm_two#/}"
    stem_two="${stem_two//\//-}"
    stem_two="${stem_two//./_}"
    stem_two="${stem_two//:/_}"
    hash_output=$(printf '%s' "$norm_one" | sha256sum)
    hash_one="${hash_output%% *}"
    hash_output=$(printf '%s' "$norm_two" | sha256sum)
    hash_two="${hash_output%% *}"
    short_hostname=$(hostname -s)
    short_hostname="${short_hostname//./_}"
    short_hostname="${short_hostname//:/_}"
    norm_one_name="${stem_one}-${hash_one:0:12}-${short_hostname}"
    norm_two_name="${stem_two}-${hash_two:0:12}-${short_hostname}"
    assert_contains "$LAST_TRANSCRIPT" \
        "${stem_one}-${hash_one:0:12}  $norm_one" \
        "first normalized catalog collision omitted its path hash"
    assert_contains "$LAST_TRANSCRIPT" \
        "${stem_two}-${hash_two:0:12}  $norm_two" \
        "second normalized catalog collision omitted its path hash"
    send_current_input 'x\n'
    finish_current_pty
    stop_state_monitor catalog-discovery-first
    assert_last_pty_failed_without_timeout "first catalog inspection"

    start_state_monitor catalog-discovery-second "$root"
    start_runner_outside catalog-discovery-second "$root" "$home" "$xdg_home" \
        "$RUNNER" repo
    if ! wait_for_transcript_text "Select repository:"; then
        fail_test "second repository discovery did not reach its prompt"
    fi
    rows_two=$(repository_rows "$LAST_TRANSCRIPT")
    assert_equal "$rows_one" "$rows_two" \
        "repository catalog ordering changed between runs"
    send_current_input 'x\n'
    finish_current_pty
    stop_state_monitor catalog-discovery-second
    chmod 0700 "$unreadable_subtree"
    assert_last_pty_failed_without_timeout "second catalog inspection"

    create_tmux_root catalog-discovery-first-order
    first_order_root="$NEW_TMUX_ROOT"
    run_repo_selection_success catalog-discovery-first-order-one "$first_order_root" \
        "$home" "$xdg_home" "$norm_one_name" "$norm_one"
    run_repo_selection_success catalog-discovery-first-order-two "$first_order_root" \
        "$home" "$xdg_home" "$norm_two_name" "$norm_two"
    assert_equal "$norm_one_name" \
        "$(session_name_for_path "$first_order_root" "$norm_one")" \
        "first selection order changed the first normalized session name"
    assert_equal "$norm_two_name" \
        "$(session_name_for_path "$first_order_root" "$norm_two")" \
        "first selection order changed the second normalized session name"
    assert_equal "$norm_one" \
        "$(pane_directory "$first_order_root" "$norm_one_name")" \
        "first selection order opened the first normalized repository elsewhere"
    assert_equal "$norm_two" \
        "$(pane_directory "$first_order_root" "$norm_two_name")" \
        "first selection order opened the second normalized repository elsewhere"

    create_tmux_root catalog-discovery-second-order
    second_order_root="$NEW_TMUX_ROOT"
    run_repo_selection_success catalog-discovery-second-order-two "$second_order_root" \
        "$home" "$xdg_home" "$norm_two_name" "$norm_two"
    run_repo_selection_success catalog-discovery-second-order-one "$second_order_root" \
        "$home" "$xdg_home" "$norm_one_name" "$norm_one"
    assert_equal "$norm_one_name" \
        "$(session_name_for_path "$second_order_root" "$norm_one")" \
        "opposite selection order changed the first normalized session name"
    assert_equal "$norm_two_name" \
        "$(session_name_for_path "$second_order_root" "$norm_two")" \
        "opposite selection order changed the second normalized session name"
    assert_equal "$norm_one" \
        "$(pane_directory "$second_order_root" "$norm_one_name")" \
        "opposite selection order opened the first normalized repository elsewhere"
    assert_equal "$norm_two" \
        "$(pane_directory "$second_order_root" "$norm_two_name")" \
        "opposite selection order opened the second normalized repository elsewhere"
    pass_test CATALOG-DISCOVERY "real Git discovery, deduplication, and stable labels"
}

function test_catalog_selection {
    local root=""
    local opposite_root=""
    local ambient_root=""
    local home="$WORKSPACE/catalog-selection/home"
    local xdg_home="$WORKSPACE/catalog-selection/xdg"
    local repos_file="$xdg_home/tmux-runner/repos"
    local catalog_root="$WORKSPACE/catalog-selection/catalog"
    local left_repo="$catalog_root/left/shared"
    local right_repo="$catalog_root/right/shared"
    local concurrent_repo="$catalog_root/concurrent"
    local legacy_repo="$catalog_root/legacy"
    local ambient_repository="$WORKSPACE/catalog-selection/ambient"
    local short_hostname=""
    local left_name=""
    local right_name=""
    local concurrent_name=""
    local identity_before=""
    local number=""

    create_tmux_root catalog-selection
    root="$NEW_TMUX_ROOT"
    mkdir -p -- "$home" "${repos_file%/*}" "$catalog_root"
    init_git_repository "$left_repo"
    init_git_repository "$right_repo"
    init_git_repository "$concurrent_repo"
    init_git_repository "$legacy_repo"
    init_git_repository "$ambient_repository"
    printf '%s\n' "$catalog_root" > "$repos_file"
    short_hostname=$(hostname -s)
    short_hostname="${short_hostname//./_}"
    short_hostname="${short_hostname//:/_}"
    left_name="left-shared-$short_hostname"
    right_name="right-shared-$short_hostname"
    concurrent_name="concurrent-$short_hostname"

    run_outside_success catalog-selection-create-catalog "$root" "$home" "$xdg_home" \
        "$RUNNER" "$right_name" create -c "$right_repo"
    assert_equal "$right_repo" "$(session_path "$root" "$right_name")" \
        "catalogued create did not use the stable catalog label"

    run_repo_selection_success catalog-selection-left-first "$root" "$home" \
        "$xdg_home" "$left_name" "$left_repo"
    identity_before=$(session_identity "$root" "$left_name")
    run_repo_selection_success catalog-selection-left-reuse "$root" "$home" \
        "$xdg_home" "$left_name" "$left_repo"
    assert_equal "$identity_before" "$(session_identity "$root" "$left_name")" \
        "repository reselection did not reuse its session"

    run_concurrent_repo_selection catalog-selection-concurrent "$root" "$home" \
        "$xdg_home" "$concurrent_repo" "$concurrent_name"
    assert_equal "$concurrent_repo" \
        "$(session_path "$root" "$concurrent_name")" \
        "concurrent selectors recorded the wrong path"

    run_outside_success catalog-selection-legacy-create "$root" "$home" "$xdg_home" \
        "$RUNNER" legacy-explicit create -s legacy-explicit -c "$legacy_repo"
    run_repo_selection_success catalog-selection-legacy-select "$root" "$home" \
        "$xdg_home" legacy-explicit "$legacy_repo"
    if run_tmux "$root" has-session -t "=legacy-$short_hostname" \
        2>/dev/null; then
        fail_test "repository selection renamed an existing path session"
    fi

    create_tmux_root catalog-selection-opposite
    opposite_root="$NEW_TMUX_ROOT"
    run_repo_selection_success catalog-selection-opposite-left "$opposite_root" \
        "$home" "$xdg_home" "$left_name" "$left_repo"
    run_repo_selection_success catalog-selection-opposite-right "$opposite_root" \
        "$home" "$xdg_home" "$right_name" "$right_repo"
    assert_equal "$left_repo" \
        "$(session_path "$opposite_root" "$left_name")" \
        "opposite selection order changed the left catalog identity"
    assert_equal "$right_repo" \
        "$(session_path "$opposite_root" "$right_name")" \
        "opposite selection order changed the right catalog identity"

    create_tmux_root catalog-selection-ambient
    ambient_root="$NEW_TMUX_ROOT"
    start_pty_command catalog-selection-ambient "$ambient_root" "$home" "$xdg_home" \
        env GIT_DIR="$ambient_repository/.git" \
        GIT_WORK_TREE="$ambient_repository" bash -x "$RUNNER" repo
    if ! wait_for_transcript_text "Select repository:"; then
        fail_test "ambient Git repository selection did not display its prompt"
    fi
    number=$(repository_selection_number "$LAST_TRANSCRIPT" "$left_repo")
    if [[ -z "$number" ]]; then
        fail_test "ambient Git repository selection omitted the target"
    fi
    send_current_input "$number\n"
    if ! wait_for_client_session "$ambient_root" "$left_name"; then
        fail_test "ambient Git repository selection did not reach $left_name"
    fi
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "ambient Git repository selection failed"
    assert_equal "$left_repo" \
        "$(session_path "$ambient_root" "$left_name")" \
        "ambient Git controls changed repository selection identity"
    pass_test CATALOG-SELECTION "catalogued create, reuse, concurrency, and legacy reuse"
}

function test_catalog_failures {
    local root=""
    local home="$WORKSPACE/catalog-failures/home"
    local xdg_home="$WORKSPACE/catalog-failures/xdg"
    local empty_xdg="$WORKSPACE/catalog-failures/empty-xdg"
    local repos_file="$xdg_home/tmux-runner/repos"
    local empty_repos="$empty_xdg/tmux-runner/repos"
    local catalog_root="$WORKSPACE/catalog-failures/catalog"
    local repository="$catalog_root/project"
    local moved_repository="$catalog_root/project.removed"
    local plain_root="$WORKSPACE/catalog-failures/plain-root"
    local number=""

    create_tmux_root catalog-failures
    root="$NEW_TMUX_ROOT"
    mkdir -p -- "$home" "${repos_file%/*}" "${empty_repos%/*}" \
        "$catalog_root" "$plain_root"
    init_git_repository "$repository"
    printf '%s\n' "$catalog_root" > "$repos_file"
    printf '%s\n' "$plain_root" > "$empty_repos"
    run_tmux "$root" -f /dev/null new-session -d -s failure-sentinel

    start_state_monitor catalog-failures-text "$root"
    start_runner_outside catalog-failures-text "$root" "$home" "$xdg_home" \
        "$RUNNER" repo
    wait_for_transcript_text "Select repository:" || \
        fail_test "nonnumeric repository case omitted its prompt"
    send_current_input 'not-a-number\n'
    finish_current_pty
    stop_state_monitor catalog-failures-text
    assert_last_pty_failed_without_timeout "nonnumeric repository selection"

    start_state_monitor catalog-failures-range "$root"
    start_runner_outside catalog-failures-range "$root" "$home" "$xdg_home" \
        "$RUNNER" repo
    wait_for_transcript_text "Select repository:" || \
        fail_test "range repository case omitted its prompt"
    send_current_input '18446744073709551617\n'
    finish_current_pty
    stop_state_monitor catalog-failures-range
    assert_last_pty_failed_without_timeout "range repository selection"

    run_outside_failure catalog-failures-empty "$root" "$home" "$empty_xdg" \
        "$RUNNER" repo
    assert_contains "$LAST_TRANSCRIPT" "no Git working trees found" \
        "empty repository discovery omitted its error"

    start_state_monitor catalog-failures-removed "$root"
    start_runner_outside catalog-failures-removed "$root" "$home" "$xdg_home" \
        "$RUNNER" repo
    wait_for_transcript_text "Select repository:" || \
        fail_test "removed repository case omitted its prompt"
    number=$(repository_selection_number "$LAST_TRANSCRIPT" "$repository")
    mv -- "$repository" "$moved_repository"
    send_current_input "$number\n"
    finish_current_pty
    mv -- "$moved_repository" "$repository"
    stop_state_monitor catalog-failures-removed
    assert_last_pty_failed_without_timeout "removed repository selection"
    assert_contains "$LAST_TRANSCRIPT" "no longer accessible" \
        "removed repository error omitted revalidation guidance"

    start_state_monitor catalog-failures-changed "$root"
    start_runner_outside catalog-failures-changed "$root" "$home" "$xdg_home" \
        "$RUNNER" repo
    wait_for_transcript_text "Select repository:" || \
        fail_test "changed repository case omitted its prompt"
    number=$(repository_selection_number "$LAST_TRANSCRIPT" "$repository")
    mv -- "$repository/.git" "$repository/.git.removed"
    send_current_input "$number\n"
    finish_current_pty
    mv -- "$repository/.git.removed" "$repository/.git"
    stop_state_monitor catalog-failures-changed
    assert_last_pty_failed_without_timeout "changed repository selection"
    assert_contains "$LAST_TRANSCRIPT" "no longer a Git working tree" \
        "changed repository error omitted revalidation guidance"

    start_state_monitor catalog-failures-final-recheck "$root"
    start_entry_gated_runner_outside catalog-failures-final-recheck "$root" "$home" \
        "$xdg_home" "$RUNNER" list-sessions repo
    wait_for_transcript_text "Select repository:" || \
        fail_test "final repository recheck case omitted its prompt"
    number=$(repository_selection_number "$LAST_TRANSCRIPT" "$repository")
    send_current_input "$number\n"
    if ! wait_for_file "$ENTRY_GATE_READY"; then
        fail_test "final repository recheck did not reach its entry gate"
    fi
    mv -- "$repository/.git" "$repository/.git.final-recheck"
    release_entry_gate
    finish_current_pty
    mv -- "$repository/.git.final-recheck" "$repository/.git"
    ENTRY_GATE_READY=""
    ENTRY_GATE_RELEASE=""
    stop_state_monitor catalog-failures-final-recheck
    assert_last_pty_failed_without_timeout "final repository recheck"
    assert_contains "$LAST_TRANSCRIPT" \
        "path kind changed before tmux entry" \
        "final repository recheck error omitted the changed identity"

    run_outside_success catalog-failures-explicit-one "$root" "$home" "$xdg_home" \
        "$RUNNER" repo-explicit-one create -s repo-explicit-one \
        -c "$repository"
    run_outside_success catalog-failures-explicit-two "$root" "$home" "$xdg_home" \
        "$RUNNER" repo-explicit-two create -s repo-explicit-two \
        -c "$repository"
    start_state_monitor catalog-failures-ambiguous "$root"
    start_runner_outside catalog-failures-ambiguous "$root" "$home" "$xdg_home" \
        "$RUNNER" repo
    wait_for_transcript_text "Select repository:" || \
        fail_test "ambiguous repository case omitted its prompt"
    number=$(repository_selection_number "$LAST_TRANSCRIPT" "$repository")
    send_current_input "$number\n"
    finish_current_pty
    stop_state_monitor catalog-failures-ambiguous
    assert_last_pty_failed_without_timeout "ambiguous repository selection"
    assert_contains "$LAST_TRANSCRIPT" "repo-explicit-one" \
        "ambiguous repository error omitted the first exact name"
    assert_contains "$LAST_TRANSCRIPT" "repo-explicit-two" \
        "ambiguous repository error omitted the second exact name"
    pass_test CATALOG-FAILURES "invalid, empty, stale, changed, and ambiguous failures"
}

function test_catalog_regression {
    local installed_runner="$WORKSPACE/t6/home with space/.local/bin/tmux-runner"
    local installed_help="$WORKSPACE/catalog-regression-installed-help"

    assert_contains "$WORKSPACE/t8/top-long.stdout" "repo" \
        "top-level help omits repository discovery"
    assert_contains "$WORKSPACE/t8/repo-long.stdout" \
        "Add one literal absolute search root per line." \
        "repo help omits literal configuration guidance"
    env PATH=/nonexistent /bin/bash "$installed_runner" repo --help \
        > "$installed_help"
    assert_contains "$installed_help" "Usage: tmux-runner repo" \
        "installed runner omits repo help"
    assert_contains "$README" "## Repository Catalog" \
        "README omits repository catalog behavior"
    assert_contains "$README" "tmux-runner repo" \
        "README omits the repository selector command"
    assert_contains "$README" "literal absolute" \
        "README omits literal repository root parsing"
    pass_test CATALOG-REGRESSION "help, completion, installation, docs, and core-through-identity regression"
}

function test_navigation_recent {
    local root=""
    local home="$WORKSPACE/navigation-recent/home"
    local xdg_home="$WORKSPACE/navigation-recent/xdg"
    local state_home="$WORKSPACE/navigation-recent/state-home"
    local state_directory=""
    local state_file=""
    local repos_file="$xdg_home/tmux-runner/repos"
    local catalog_root="$WORKSPACE/navigation-recent/catalog"
    local repository_b="$catalog_root/repo-b"
    local ambient_repository="$WORKSPACE/navigation-recent/ambient"
    local path_a="$WORKSPACE/navigation-recent/path-a"
    local repository_git_backup="$repository_b/.git.saved"
    local path_a_git_backup="$WORKSPACE/navigation-recent/path-a.git"
    local bulk_root="$WORKSPACE/navigation-recent/bulk"
    local short_hostname=""
    local repository_b_name=""
    local path_a_name=""
    local identity_before=""
    local path=""
    local suffix=""
    local expected_paths=""
    local actual_paths=""
    local snapshot_before=""
    local number=""
    local index=0
    local -a bulk_paths=()

    create_tmux_root navigation-recent
    root="$NEW_TMUX_ROOT"
    export XDG_STATE_HOME="$state_home"
    state_directory=$(runner_state_directory_for "$state_home")
    state_file="$state_directory/state"
    mkdir -p -- "$home" "${repos_file%/*}" "$path_a" "$bulk_root"
    init_git_repository "$repository_b"
    init_git_repository "$ambient_repository"
    printf '%s\n' "$catalog_root" > "$repos_file"
    short_hostname=$(hostname -s)
    short_hostname="${short_hostname//./_}"
    short_hostname="${short_hostname//:/_}"
    repository_b_name="repo-b-$short_hostname"
    path_a_name="path-a-$short_hostname"

    run_outside_success navigation-recent-create-a "$root" "$home" "$xdg_home" \
        "$RUNNER" m6-a create -s m6-a -c "$path_a"
    run_repo_selection_success navigation-recent-repo-b "$root" "$home" \
        "$xdg_home" "$repository_b_name" "$repository_b"
    start_pty_command navigation-recent-recent-ambient "$root" "$home" "$xdg_home" \
        env GIT_DIR="$ambient_repository/.git" \
        GIT_WORK_TREE="$ambient_repository" bash -x "$RUNNER" recent
    if ! wait_for_transcript_text "Select recent destination:"; then
        fail_test "ambient Git recent selection did not display its prompt"
    fi
    number=$(recent_selection_number "$LAST_TRANSCRIPT" "$repository_b")
    if [[ -z "$number" ]]; then
        fail_test "ambient Git recent selection omitted the target"
    fi
    send_current_input "$number\n"
    if ! wait_for_client_session "$root" "$repository_b_name"; then
        fail_test "ambient Git recent selection did not reach $repository_b_name"
    fi
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "ambient Git recent selection failed"
    assert_equal "$repository_b" \
        "$(session_path "$root" "$repository_b_name")" \
        "ambient Git controls changed recent destination identity"
    assert_equal "git" \
        "$(state_recent_kind_for_path "$state_file" "$repository_b")" \
        "Git recent destination did not retain its kind"
    assert_equal "plain" \
        "$(state_recent_kind_for_path "$state_file" "$path_a")" \
        "plain recent destination did not retain its kind"

    snapshot_before=$(state_snapshot "$state_directory")
    start_state_monitor navigation-recent-recent-final-recheck "$root"
    start_entry_gated_runner_outside navigation-recent-recent-final-recheck "$root" \
        "$home" "$xdg_home" "$RUNNER" list-sessions recent
    if ! wait_for_transcript_text "Select recent destination:"; then
        fail_test "final recent recheck case did not display its prompt"
    fi
    number=$(recent_selection_number "$LAST_TRANSCRIPT" "$repository_b")
    if [[ -z "$number" ]]; then
        fail_test "final recent recheck case omitted the target"
    fi
    send_current_input "$number\n"
    if ! wait_for_file "$ENTRY_GATE_READY"; then
        fail_test "final recent recheck did not reach its entry gate"
    fi
    mv -- "$repository_b/.git" "$repository_git_backup"
    release_entry_gate
    finish_current_pty
    mv -- "$repository_git_backup" "$repository_b/.git"
    ENTRY_GATE_READY=""
    ENTRY_GATE_RELEASE=""
    stop_state_monitor navigation-recent-recent-final-recheck
    assert_last_pty_failed_without_timeout "final recent recheck"
    assert_contains "$LAST_TRANSCRIPT" \
        "path kind changed before tmux entry" \
        "final recent recheck error omitted the changed identity"
    assert_equal "$snapshot_before" "$(state_snapshot "$state_directory")" \
        "final recent recheck changed navigation state"

    mv -- "$repository_b/.git" "$repository_git_backup"
    start_runner_outside navigation-recent-recent-git-to-plain "$root" "$home" \
        "$xdg_home" "$RUNNER" recent
    if ! wait_for_transcript_text "Select recent destination:"; then
        fail_test "Git-to-plain recent case did not display its prompt"
    fi
    number=$(recent_selection_number "$LAST_TRANSCRIPT" "$repository_b")
    assert_equal "" "$number" \
        "Git-to-plain destination remained eligible in recent"
    send_current_input 'not-a-number\n'
    finish_current_pty
    assert_last_pty_failed_without_timeout \
        "Git-to-plain recent inspection"
    mv -- "$repository_git_backup" "$repository_b/.git"

    git -C "$path_a" init -q
    git -C "$path_a" config core.hooksPath /dev/null
    start_runner_outside navigation-recent-recent-plain-to-git "$root" "$home" \
        "$xdg_home" "$RUNNER" recent
    if ! wait_for_transcript_text "Select recent destination:"; then
        fail_test "plain-to-Git recent case did not display its prompt"
    fi
    number=$(recent_selection_number "$LAST_TRANSCRIPT" "$path_a")
    assert_equal "" "$number" \
        "plain-to-Git destination remained eligible in recent"
    send_current_input 'not-a-number\n'
    finish_current_pty
    assert_last_pty_failed_without_timeout \
        "plain-to-Git recent inspection"
    mv -- "$path_a/.git" "$path_a_git_backup"

    identity_before=$(session_identity "$root" m6-a)
    run_recent_selection_success navigation-recent-recent-reuse "$root" "$home" \
        "$xdg_home" "$RUNNER" m6-a "$path_a"
    assert_equal "$identity_before" "$(session_identity "$root" m6-a)" \
        "recent selection did not reuse the existing path session"

    run_tmux "$root" new-session -d -s m6-unmarked-u
    run_tmux "$root" new-session -d -s m6-unmarked-v
    run_outside_success navigation-recent-direct-marked "$root" "$home" "$xdg_home" \
        "$RUNNER" "$repository_b_name" attach "$repository_b_name"
    recent_before_unmarked=$(state_record_values recent "$state_file")
    run_outside_success navigation-recent-direct-unmarked "$root" "$home" "$xdg_home" \
        "$RUNNER" m6-unmarked-u attach m6-unmarked-u
    assert_equal "$recent_before_unmarked" \
        "$(state_record_values recent "$state_file")" \
        "direct unmarked attachment changed recent paths"
    run_outside_success navigation-recent-direct-last "$root" "$home" "$xdg_home" \
        "$RUNNER" "$repository_b_name" last
    assert_session_entry_trace "$LAST_TRANSCRIPT" "$root" \
        "$repository_b_name" "last did not target the resolved session ID"
    run_list_selection_success navigation-recent-list-marked "$root" "$home" \
        "$xdg_home" "$RUNNER" m6-a
    recent_before_unmarked=$(state_record_values recent "$state_file")
    run_list_selection_success navigation-recent-list-unmarked "$root" "$home" \
        "$xdg_home" "$RUNNER" m6-unmarked-v
    assert_equal "$recent_before_unmarked" \
        "$(state_record_values recent "$state_file")" \
        "list-selected unmarked session changed recent paths"
    run_outside_success navigation-recent-list-last "$root" "$home" "$xdg_home" \
        "$RUNNER" m6-a last
    run_tmux "$root" kill-session -t '=m6-a'
    run_recent_selection_success navigation-recent-recent-recreate "$root" "$home" \
        "$xdg_home" "$RUNNER" "$path_a_name" "$path_a"
    assert_equal "$path_a" "$(session_path "$root" "$path_a_name")" \
        "recent selection recreated the wrong path identity"

    for ((index = 1; index <= 21; index++)); do
        printf -v suffix '%02d' "$index"
        path="$bulk_root/path-$suffix"
        mkdir -p -- "$path"
        bulk_paths+=("$path")
        run_outside_success "navigation-recent-bulk-$suffix" "$root" "$home" \
            "$xdg_home" "$RUNNER" "m6-bulk-$suffix" create \
            -s "m6-bulk-$suffix" -c "$path"
    done
    run_outside_success navigation-recent-bulk-repeat "$root" "$home" "$xdg_home" \
        "$RUNNER" m6-bulk-07 create -s m6-bulk-07 \
        -c "${bulk_paths[6]}"

    expected_paths=$(encode_state_field "${bulk_paths[6]}")
    for ((index = 20; index >= 7; index--)); do
        expected_paths+=$'\n'"$(encode_state_field "${bulk_paths[$index]}")"
    done
    for ((index = 5; index >= 1; index--)); do
        expected_paths+=$'\n'"$(encode_state_field "${bulk_paths[$index]}")"
    done
    actual_paths=$(state_record_values recent "$state_file")
    assert_equal "$expected_paths" "$actual_paths" \
        "recent state did not retain the newest 20 unique paths"

    start_runner_outside navigation-recent-recent-inspect "$root" "$home" "$xdg_home" \
        "$RUNNER" recent
    if ! wait_for_transcript_text "Select recent destination:"; then
        fail_test "recent inspection did not display its prompt"
    fi
    actual_paths=$(recent_display_paths "$LAST_TRANSCRIPT")
    assert_equal "$expected_paths" "$actual_paths" \
        "recent display order differs from the persisted MRU order"
    number=$(recent_selection_number "$LAST_TRANSCRIPT" "${bulk_paths[6]}")
    assert_equal "1" "$number" "repeated recent path is not first"
    send_current_input 'not-a-number\n'
    finish_current_pty
    assert_last_pty_failed_without_timeout "recent inspection invalid input"

    assert_state_modes "$state_directory"
    assert_no_state_transactions "$state_directory"
    unset XDG_STATE_HOME
    pass_test NAVIGATION-RECENT "recent commands, marked filtering, recreation, and 20-entry MRU"
}

function test_navigation_previous {
    local root=""
    local other_root=""
    local legacy_root=""
    local home="$WORKSPACE/navigation-previous/home"
    local xdg_home="$WORKSPACE/navigation-previous/xdg"
    local state_home="$WORKSPACE/navigation-previous/state-home"
    local legacy_state_home="$WORKSPACE/navigation-previous/legacy-state-home"
    local state_directory=""
    local state_file=""
    local legacy_path="$WORKSPACE/navigation-previous/legacy-path"
    local legacy_git="$WORKSPACE/navigation-previous/legacy-git"
    local legacy_name=""
    local server_identity=""
    local other_server_identity=""
    local legacy_server_identity=""
    local short_hostname=""
    local fingerprint_before=""
    local expected_sessions=""

    create_tmux_root navigation-previous
    root="$NEW_TMUX_ROOT"
    export XDG_STATE_HOME="$state_home"
    state_directory=$(runner_state_directory_for "$state_home")
    state_file="$state_directory/state"
    mkdir -p -- "$home" "$xdg_home"
    run_tmux "$root" -f /dev/null new-session -d -s m6-last-a
    run_tmux "$root" new-session -d -s m6-last-b
    fingerprint_before=$(server_identity_fingerprint "$root")

    run_outside_success navigation-previous-enter-a "$root" "$home" "$xdg_home" \
        "$RUNNER" m6-last-a attach m6-last-a
    run_outside_success navigation-previous-enter-b "$root" "$home" "$xdg_home" \
        "$RUNNER" m6-last-b attach m6-last-b
    run_outside_success navigation-previous-repeat-b "$root" "$home" "$xdg_home" \
        "$RUNNER" m6-last-b attach m6-last-b
    run_outside_success navigation-previous-last-a "$root" "$home" "$xdg_home" \
        "$RUNNER" m6-last-a last
    run_outside_success navigation-previous-last-b "$root" "$home" "$xdg_home" \
        "$RUNNER" m6-last-b last

    run_inside_success navigation-previous-inside-a "$root" "$home" "$xdg_home" \
        m6-last-b m6-last-a "$RUNNER" last
    assert_session_entry_trace "$LAST_INSIDE_TRACE" "$root" m6-last-a \
        "inside last did not switch exactly to A"
    run_inside_success navigation-previous-inside-b "$root" "$home" "$xdg_home" \
        m6-last-a m6-last-b "$RUNNER" last
    assert_session_entry_trace "$LAST_INSIDE_TRACE" "$root" m6-last-b \
        "inside last did not switch exactly to B"

    create_tmux_root navigation-previous-other
    other_root="$NEW_TMUX_ROOT"
    run_tmux "$other_root" -f /dev/null new-session -d -s m6-other-a
    run_tmux "$other_root" new-session -d -s m6-other-b
    run_outside_failure navigation-previous-other-empty-last "$other_root" "$home" \
        "$xdg_home" "$RUNNER" last
    assert_contains "$LAST_TRANSCRIPT" \
        "no previous runner session is available" \
        "last used session history from another runner server"
    run_outside_success navigation-previous-other-enter-a "$other_root" "$home" \
        "$xdg_home" "$RUNNER" m6-other-a attach m6-other-a
    run_outside_success navigation-previous-other-enter-b "$other_root" "$home" \
        "$xdg_home" "$RUNNER" m6-other-b attach m6-other-b
    run_outside_success navigation-previous-other-last-a "$other_root" "$home" \
        "$xdg_home" "$RUNNER" m6-other-a last
    run_outside_success navigation-previous-original-last-a "$root" "$home" \
        "$xdg_home" "$RUNNER" m6-last-a last

    server_identity=$(runner_socket_path_for_root "$root")
    other_server_identity=$(runner_socket_path_for_root "$other_root")
    expected_sessions=$(printf '%s\n%s\n' \
        "$(encode_state_field m6-last-a)" \
        "$(encode_state_field m6-last-b)")
    assert_equal "$expected_sessions" \
        "$(state_session_values_for_server "$state_file" \
            "$server_identity")" \
        "last did not retain two sessions for the original server"
    expected_sessions=$(printf '%s\n%s\n' \
        "$(encode_state_field m6-other-a)" \
        "$(encode_state_field m6-other-b)")
    assert_equal "$expected_sessions" \
        "$(state_session_values_for_server "$state_file" \
            "$other_server_identity")" \
        "last did not retain two sessions for the other server"
    assert_equal "" "$(state_record_values recent "$state_file")" \
        "unmarked last navigation created a recent path"
    assert_equal "$fingerprint_before" \
        "$(server_identity_fingerprint "$root")" \
        "last navigation changed session, window, or pane identity"
    assert_state_modes "$state_directory"
    assert_no_state_transactions "$state_directory"

    create_tmux_root navigation-previous-legacy
    legacy_root="$NEW_TMUX_ROOT"
    export XDG_STATE_HOME="$legacy_state_home"
    state_directory=$(runner_state_directory_for "$legacy_state_home")
    state_file="$state_directory/state"
    mkdir -p -- "$state_directory" "$legacy_path"
    init_git_repository "$legacy_git"
    chmod 0700 "$state_directory"
    {
        printf 'version\t1\n'
        printf 'sequence\t4\n'
        printf 'session\t4\t%s\n' "$(encode_state_field legacy-b)"
        printf 'session\t3\t%s\n' "$(encode_state_field legacy-a)"
        printf 'recent\t2\t%s\n' "$(encode_state_field "$legacy_git")"
        printf 'recent\t1\t%s\n' "$(encode_state_field "$legacy_path")"
    } > "$state_file"
    chmod 0600 "$state_file"
    run_tmux "$legacy_root" -f /dev/null new-session -d -s legacy-a
    run_tmux "$legacy_root" new-session -d -s legacy-b
    run_outside_failure navigation-previous-legacy-last "$legacy_root" "$home" \
        "$xdg_home" "$RUNNER" last
    assert_contains "$LAST_TRANSCRIPT" \
        "no previous runner session is available" \
        "v1 session history remained eligible for last"
    short_hostname=$(hostname -s)
    short_hostname="${short_hostname//./_}"
    short_hostname="${short_hostname//:/_}"
    legacy_name="legacy-path-$short_hostname"
    run_recent_selection_success navigation-previous-legacy-recent "$legacy_root" \
        "$home" "$xdg_home" "$RUNNER" "$legacy_name" "$legacy_path"
    assert_contains "$state_file" $'version\t2' \
        "successful v1 recent migration did not write state v2"
    legacy_server_identity=$(runner_socket_path_for_root "$legacy_root")
    assert_equal "$(encode_state_field "$legacy_name")" \
        "$(state_session_values_for_server "$state_file" \
            "$legacy_server_identity")" \
        "v1 session history survived migration into server-scoped state"
    expected_sessions=$(printf '%s\n%s\n' \
        "$(encode_state_field "$legacy_path")" \
        "$(encode_state_field "$legacy_git")")
    assert_equal "$expected_sessions" \
        "$(state_record_values recent "$state_file")" \
        "v1 recent paths did not survive state migration"
    assert_equal "plain" \
        "$(state_recent_kind_for_path "$state_file" "$legacy_path")" \
        "v1 recent path did not acquire its current kind"
    assert_equal "git" \
        "$(state_recent_kind_for_path "$state_file" "$legacy_git")" \
        "v1 Git recent path did not acquire its current kind"
    assert_state_modes "$state_directory"
    assert_no_state_transactions "$state_directory"
    unset XDG_STATE_HOME
    pass_test NAVIGATION-PREVIOUS \
        "server-scoped previous-session alternation and v1 migration"
}

function exercise_navigation_recovery_data_failures {
    local root=""
    local home="$WORKSPACE/navigation-recovery-data/home"
    local xdg_home="$WORKSPACE/navigation-recovery-data/xdg"
    local state_home="$WORKSPACE/navigation-recovery-data/state-home"
    local state_directory=""
    local state_file=""
    local valid_path="$WORKSPACE/navigation-recovery-data/valid-path"
    local stale_path="$WORKSPACE/navigation-recovery-data/stale-path"
    local moved_path="$WORKSPACE/navigation-recovery-data/stale-path.moved"
    local special_path=""
    local sentinel="$WORKSPACE/navigation-recovery-data/shell-evaluated"
    local malicious_path=""
    local encoded_special=""
    local snapshot_before=""
    local snapshot_after=""
    local fingerprint_before=""
    local number=""
    local valid_backup="$WORKSPACE/navigation-recovery-data/state.valid"

    create_tmux_root navigation-recovery-data
    root="$NEW_TMUX_ROOT"
    export XDG_STATE_HOME="$state_home"
    state_directory=$(runner_state_directory_for "$state_home")
    state_file="$state_directory/state"
    special_path="$WORKSPACE/navigation-recovery-data/special"$'\t'"percent%"$'\n'"line"$'\r'
    malicious_path="$WORKSPACE/navigation-recovery-data/\$(touch\${IFS}$sentinel)"
    mkdir -p -- "$home" "$xdg_home" "$valid_path" "$stale_path" \
        "$special_path"

    run_outside_success navigation-recovery-data-valid "$root" "$home" "$xdg_home" \
        "$RUNNER" m6-data-valid create -s m6-data-valid -c "$valid_path"
    run_outside_success navigation-recovery-data-stale "$root" "$home" "$xdg_home" \
        "$RUNNER" m6-data-stale create -s m6-data-stale -c "$stale_path"
    run_outside_success navigation-recovery-data-special "$root" "$home" "$xdg_home" \
        "$RUNNER" m6-data-special create -s m6-data-special \
        -c "$special_path"
    encoded_special=$(encode_state_field "$special_path")
    if ! grep -F -- "$encoded_special" "$state_file" >/dev/null; then
        fail_test "special recent path was not percent encoded"
    fi
    assert_contains "$state_file" "%25" \
        "state record omitted percent escaping"
    assert_contains "$state_file" "%09" \
        "state record omitted tab escaping"
    assert_contains "$state_file" "%0A" \
        "state record omitted newline escaping"

    snapshot_before=$(state_snapshot "$state_directory")
    run_outside_failure navigation-recovery-invalid-recent-args "$root" "$home" \
        "$xdg_home" "$RUNNER" recent extra
    run_outside_failure navigation-recovery-invalid-last-args "$root" "$home" \
        "$xdg_home" "$RUNNER" last extra
    start_state_monitor navigation-recovery-invalid-recent-number "$root"
    start_runner_outside navigation-recovery-invalid-recent-number "$root" "$home" \
        "$xdg_home" "$RUNNER" recent
    if ! wait_for_transcript_text "Select recent destination:"; then
        fail_test "invalid recent number case omitted its prompt"
    fi
    send_current_input 'not-a-number\n'
    finish_current_pty
    stop_state_monitor navigation-recovery-invalid-recent-number
    assert_last_pty_failed_without_timeout "invalid recent number"
    run_outside_failure navigation-recovery-missing-attach "$root" "$home" "$xdg_home" \
        "$RUNNER" attach m6-missing-target
    snapshot_after=$(state_snapshot "$state_directory")
    assert_equal "$snapshot_before" "$snapshot_after" \
        "invalid commands changed navigation state"

    mv -- "$stale_path" "$moved_path"
    start_runner_outside navigation-recovery-stale-path "$root" "$home" "$xdg_home" \
        "$RUNNER" recent
    if ! wait_for_transcript_text "Select recent destination:"; then
        fail_test "stale recent path case omitted its prompt"
    fi
    number=$(recent_selection_number "$LAST_TRANSCRIPT" "$stale_path")
    assert_equal "" "$number" "stale path remained visible in recent"
    send_current_input 'not-a-number\n'
    finish_current_pty
    assert_last_pty_failed_without_timeout "stale recent path inspection"
    mv -- "$moved_path" "$stale_path"

    snapshot_before=$(state_snapshot "$state_directory")
    run_tmux "$root" kill-session -t '=m6-data-stale'
    start_runner_outside navigation-recovery-stale-last "$root" "$home" "$xdg_home" \
        "$RUNNER" last
    finish_current_pty
    assert_last_pty_failed_without_timeout "stale previous session"
    assert_contains "$LAST_TRANSCRIPT" \
        "previous runner session no longer exists: m6-data-stale" \
        "stale previous session error omitted the exact target"
    snapshot_after=$(state_snapshot "$state_directory")
    assert_equal "$snapshot_before" "$snapshot_after" \
        "stale previous-session failure changed navigation state"

    {
        printf '%s\n' 'malformed-line'
        printf 'future-field\tvalue\n'
        printf 'recent\tbad-sequence\tplain\t%s\n' "$malicious_path"
        printf 'recent\t999\tplain\t%s%%GG\n' "$malicious_path"
        printf 'recent\t998\tplain\t%s\n' "$malicious_path"
        printf 'recent\t997\tunknown\t%s\n' "$malicious_path"
        printf 'session\t996\trelative-server\tmalformed-session\n'
    } >> "$state_file"
    run_recent_selection_success navigation-recovery-malformed-valid "$root" "$home" \
        "$xdg_home" "$RUNNER" m6-data-special "$special_path"
    if [[ -e "$sentinel" ]]; then
        fail_test "state data executed stored shell syntax"
    fi
    assert_not_contains "$state_file" "malformed-line" \
        "successful update retained a malformed state row"
    assert_not_contains "$state_file" $'future-field\tvalue' \
        "successful update retained an unknown state row"
    assert_not_contains "$state_file" "malformed-session" \
        "successful update retained a relative server identity"
    assert_contains "$state_file" "$encoded_special" \
        "valid special path did not survive malformed rows"

    cp "$state_file" "$valid_backup"
    sed 's/^version\t2$/version\t999/' "$valid_backup" > "$state_file"
    snapshot_before=$(state_snapshot "$state_directory")
    fingerprint_before=$(server_fingerprint "$root")
    start_runner_outside navigation-recovery-future-version "$root" "$home" "$xdg_home" \
        "$RUNNER" recent
    finish_current_pty
    assert_last_pty_failed_without_timeout "future state version"
    assert_contains "$LAST_TRANSCRIPT" \
        "state version is incompatible or unreadable" \
        "future-version state error is unclear"
    snapshot_after=$(state_snapshot "$state_directory")
    assert_equal "$snapshot_before" "$snapshot_after" \
        "future-version state was overwritten"
    assert_equal "$fingerprint_before" "$(server_fingerprint "$root")" \
        "future-version state access changed tmux state"
    if [[ -e "$sentinel" ]]; then
        fail_test "future-version state executed stored shell syntax"
    fi
    cp "$valid_backup" "$state_file"
    chmod 0600 "$state_file"

    assert_state_modes "$state_directory"
    assert_no_state_transactions "$state_directory"
    unset XDG_STATE_HOME
}

function exercise_navigation_recovery_lock_timeout {
    local root=""
    local home="$WORKSPACE/navigation-recovery-lock/home"
    local xdg_home="$WORKSPACE/navigation-recovery-lock/xdg"
    local state_home="$WORKSPACE/navigation-recovery-lock/state-home"
    local state_directory=""
    local state_file=""
    local snapshot_before=""
    local socket_path=""

    create_tmux_root navigation-recovery-lock
    root="$NEW_TMUX_ROOT"
    export XDG_STATE_HOME="$state_home"
    state_directory=$(runner_state_directory_for "$state_home")
    state_file="$state_directory/state"
    mkdir -p -- "$home" "$xdg_home" "$state_directory"
    chmod 0700 "$state_directory"
    printf 'version\t2\nsequence\t0\n' > "$state_file"
    chmod 0600 "$state_file"
    snapshot_before=$(state_snapshot "$state_directory")

    start_state_lock_holder navigation-recovery-lock "$state_directory"
    start_runner_outside navigation-recovery-lock-timeout "$root" "$home" "$xdg_home" \
        "$RUNNER" recent
    finish_current_pty
    assert_last_pty_failed_without_timeout "state lock timeout"
    assert_contains "$LAST_TRANSCRIPT" "state lock timed out after 5 seconds" \
        "state lock timeout error is unclear"
    socket_path=$(find "$root" -type s -print -quit)
    assert_equal "" "$socket_path" \
        "state lock timeout connected to or started tmux"
    assert_equal "$snapshot_before" "$(state_snapshot "$state_directory")" \
        "state lock timeout changed state"
    start_runner_outside navigation-recovery-list-lock-timeout "$root" "$home" \
        "$xdg_home" "$RUNNER" ls
    finish_current_pty
    assert_last_pty_failed_without_timeout "list state lock timeout"
    assert_contains "$LAST_TRANSCRIPT" \
        "state lock timed out after 5 seconds" \
        "list connected to tmux before acquiring the state lock"
    assert_equal "$snapshot_before" "$(state_snapshot "$state_directory")" \
        "list lock timeout changed state"
    stop_state_lock_holder navigation-recovery-lock
    unset XDG_STATE_HOME
}

function exercise_navigation_recovery_post_handoff_lock {
    local root=""
    local home="$WORKSPACE/navigation-recovery-post-lock/home"
    local xdg_home="$WORKSPACE/navigation-recovery-post-lock/xdg"
    local state_home="$WORKSPACE/navigation-recovery-post-lock/state-home"
    local state_directory=""
    local state_file=""
    local session_path="$WORKSPACE/navigation-recovery-post-lock/path"
    local pending_file=""
    local ack_file=""

    create_tmux_root navigation-recovery-post-lock
    root="$NEW_TMUX_ROOT"
    export XDG_STATE_HOME="$state_home"
    state_directory=$(runner_state_directory_for "$state_home")
    state_file="$state_directory/state"
    mkdir -p -- "$home" "$xdg_home" "$session_path"
    run_tmux "$root" new-session -d -s m6-post-lock -c "$session_path"
    run_tmux "$root" set-option -t '=m6-post-lock:' \
        @tmux-runner-path "$session_path"

    start_gated_runner_outside navigation-recovery-post-lock "$root" "$home" \
        "$xdg_home" "$RUNNER" m6-post-lock attach m6-post-lock
    if ! wait_for_pending_file "$state_directory"; then
        fail_test "post-handoff lock case did not publish a pending record"
    fi
    pending_file="$LAST_PENDING_FILE"
    ack_file=$(acknowledged_record_for_pending "$pending_file")
    start_state_lock_holder navigation-recovery-post-lock "$state_directory"
    release_attach_gate
    if ! wait_for_pending_ack "$pending_file"; then
        fail_test "post-handoff lock blocked acknowledgment publication"
    fi
    sleep 6
    assert_versioned_transaction_record "$ack_file" \
        "post-handoff lock acknowledgment"
    if ! kill -0 "$CURRENT_PTY_PID" 2>/dev/null; then
        fail_test "post-handoff lock ended the attached runner"
    fi
    stop_state_lock_holder navigation-recovery-post-lock
    if ! wait_for_first_state_value "$state_file" session \
        "$(encode_state_field m6-post-lock)"; then
        fail_test "post-handoff acknowledgment was not reconciled"
    fi
    if ! wait_for_client_session "$root" m6-post-lock; then
        fail_test "post-handoff lock case did not keep the client attached"
    fi
    detach_current_client
    finish_current_pty
    ATTACH_GATE_READY=""
    ATTACH_GATE_RELEASE=""
    assert_last_pty_succeeded "post-handoff lock attachment failed"
    assert_no_state_transactions "$state_directory"
    unset XDG_STATE_HOME
}

function exercise_navigation_recovery_transactions {
    local root=""
    local home="$WORKSPACE/navigation-recovery-transactions/home"
    local xdg_home="$WORKSPACE/navigation-recovery-transactions/xdg"
    local sentinel="$WORKSPACE/navigation-recovery-transactions/shell-evaluated"
    local state_home=""
    local state_directory=""
    local state_file=""
    local path_a="$WORKSPACE/navigation-recovery-transactions/path-a"
    local path_b="$WORKSPACE/navigation-recovery-transactions/path-b"
    local path_c="$WORKSPACE/navigation-recovery-transactions/path-c"
    local pending_file=""
    local ack_file=""
    local digest_before=""
    local snapshot_before=""
    local expected_recent=""

    create_tmux_root navigation-recovery-transactions
    root="$NEW_TMUX_ROOT"
    state_home="$WORKSPACE/navigation-recovery-transactions/state ' #{session_name} % \$(touch\${IFS}$sentinel)"
    export XDG_STATE_HOME="$state_home"
    state_directory=$(runner_state_directory_for "$state_home")
    state_file="$state_directory/state"
    mkdir -p -- "$home" "$xdg_home" "$path_a" "$path_b" "$path_c"

    run_outside_success navigation-recovery-transaction-seed "$root" "$home" \
        "$xdg_home" "$RUNNER" m6-tx-a create -s m6-tx-a -c "$path_a"
    run_tmux "$root" new-session -d -s m6-tx-b -c "$path_b"
    run_tmux "$root" set-option -t '=m6-tx-b:' \
        @tmux-runner-path "$path_b"
    run_tmux "$root" new-session -d -s m6-tx-c -c "$path_c"
    run_tmux "$root" set-option -t '=m6-tx-c:' \
        @tmux-runner-path "$path_c"

    start_gated_runner_outside navigation-recovery-unack-interleave "$root" "$home" \
        "$xdg_home" "$RUNNER" m6-tx-b attach m6-tx-b
    if ! wait_for_pending_file "$state_directory"; then
        fail_test "unacknowledged attach did not publish a pending record"
    fi
    pending_file="$LAST_PENDING_FILE"
    assert_versioned_transaction_record "$pending_file" \
        "unacknowledged interleaved pending transaction"
    run_extra_outside_success navigation-recovery-interleaved-success "$root" "$home" \
        "$xdg_home" "$RUNNER" m6-tx-c attach m6-tx-c
    run_tmux "$root" kill-session -t '=m6-tx-b'
    release_attach_gate
    finish_current_pty
    ATTACH_GATE_READY=""
    ATTACH_GATE_RELEASE=""
    assert_last_pty_failed_without_timeout \
        "unacknowledged interleaved attachment"
    if ! wait_for_no_state_transactions "$state_directory"; then
        fail_test "unacknowledged interleaved transaction did not settle"
    fi
    assert_equal "$(encode_state_field m6-tx-c)" \
        "$(state_record_values session "$state_file" | sed -n '1p')" \
        "unacknowledged rollback removed a later successful session"
    expected_recent=$(printf '%s\n%s\n' \
        "$(encode_state_field "$path_c")" \
        "$(encode_state_field "$path_a")")
    assert_equal "$expected_recent" \
        "$(state_record_values recent "$state_file")" \
        "unacknowledged rollback restored stale recent state"

    run_tmux "$root" new-session -d -s m6-tx-b -c "$path_b"
    run_tmux "$root" set-option -t '=m6-tx-b:' \
        @tmux-runner-path "$path_b"
    digest_before=$(sha256sum "$state_file")
    digest_before="${digest_before%% *}"
    start_gated_runner_outside navigation-recovery-unack-orphan "$root" "$home" \
        "$xdg_home" "$RUNNER" m6-tx-b attach m6-tx-b
    if ! wait_for_pending_file "$state_directory"; then
        fail_test "unacknowledged orphan did not publish a pending record"
    fi
    pending_file="$LAST_PENDING_FILE"
    ack_file=$(acknowledged_record_for_pending "$pending_file")
    assert_versioned_transaction_record "$pending_file" \
        "unacknowledged orphan pending transaction"
    terminate_current_pty_as_crash
    if [[ -e "$ack_file" ]]; then
        fail_test "pre-attach runner death produced an acknowledgment"
    fi
    start_runner_outside navigation-recovery-unack-reconcile "$root" "$home" \
        "$xdg_home" "$RUNNER" recent
    if ! wait_for_transcript_text "Select recent destination:"; then
        fail_test "unacknowledged orphan reconciliation omitted recent"
    fi
    send_current_input 'not-a-number\n'
    finish_current_pty
    assert_last_pty_failed_without_timeout \
        "unacknowledged orphan reconciliation input"
    assert_contains "$LAST_TRANSCRIPT" \
        "recent selection must be a number" \
        "unacknowledged orphan recovery did not reach input validation"
    assert_equal "$digest_before" \
        "$(sha256sum "$state_file" | awk '{ print $1 }')" \
        "unacknowledged orphan changed committed state"
    assert_no_state_transactions "$state_directory"

    start_gated_runner_outside navigation-recovery-ack-orphan "$root" "$home" \
        "$xdg_home" "$RUNNER" m6-tx-b attach m6-tx-b
    if ! wait_for_pending_file "$state_directory"; then
        fail_test "acknowledged orphan did not publish a pending record"
    fi
    pending_file="$LAST_PENDING_FILE"
    assert_versioned_transaction_record "$pending_file" \
        "acknowledged orphan pending transaction"
    crash_current_pty_after_acknowledgment navigation-recovery-ack-orphan \
        "$pending_file"
    assert_no_session_entry_hooks "$root" \
        "acknowledged runner death left a temporary entry hook"
    start_runner_outside navigation-recovery-ack-reconcile "$root" "$home" \
        "$xdg_home" "$RUNNER" recent
    if ! wait_for_transcript_text "Select recent destination:"; then
        fail_test "acknowledged orphan reconciliation omitted recent"
    fi
    send_current_input 'not-a-number\n'
    finish_current_pty
    assert_last_pty_failed_without_timeout \
        "acknowledged orphan reconciliation input"
    assert_contains "$LAST_TRANSCRIPT" \
        "recent selection must be a number" \
        "acknowledged orphan recovery did not precede input validation"
    assert_equal "$(encode_state_field m6-tx-b)" \
        "$(state_record_values session "$state_file" | sed -n '1p')" \
        "acknowledged orphan was not committed"
    assert_equal "$(encode_state_field "$path_b")" \
        "$(state_record_values recent "$state_file" | sed -n '1p')" \
        "acknowledged orphan path was not committed"
    assert_no_state_transactions "$state_directory"

    start_runner_outside navigation-recovery-ack-abnormal "$root" "$home" \
        "$xdg_home" "$RUNNER" attach m6-tx-c
    if ! wait_for_client_session "$root" m6-tx-c; then
        fail_test "acknowledged abnormal case did not attach a live client"
    fi
    if ! wait_for_first_state_value "$state_file" session \
        "$(encode_state_field m6-tx-c)"; then
        fail_test "outside attachment was not committed while client was live"
    fi
    if ! wait_for_no_state_transactions "$state_directory"; then
        fail_test "outside attachment was not settled while client was live"
    fi
    if ! kill -0 "$CURRENT_PTY_PID" 2>/dev/null; then
        fail_test "outside runner exited before its live-client check"
    fi
    if ! flock -n "$state_directory" true; then
        fail_test "live outside attachment inherited the state directory lock"
    fi
    snapshot_before=$(state_snapshot "$state_directory")
    run_tmux "$root" kill-server
    finish_current_pty
    assert_last_pty_failed_without_timeout \
        "acknowledged attachment after server loss"
    assert_equal "$snapshot_before" "$(state_snapshot "$state_directory")" \
        "server loss changed acknowledged state"
    if [[ -e "$sentinel" ]]; then
        fail_test "acknowledgment path executed shell syntax"
    fi
    assert_state_modes "$state_directory"
    assert_no_state_transactions "$state_directory"
    unset XDG_STATE_HOME
}

function corrupt_transaction_record {
    local record_file="$1"
    local record_kind="$2"
    local corruption="$3"
    local target_record=""
    local target_line=""
    local line=""
    local record_type=""
    local inode_before=""
    local target_count=0
    local -a lines=()

    case "$record_kind" in
        pending)
            target_record=kind
            ;;
        ack)
            target_record=sequence
            ;;
        *)
            fail_test "unknown transaction record kind: $record_kind"
            ;;
    esac
    case "$corruption" in
        missing | duplicate | unknown | raw-tab)
            ;;
        *)
            fail_test "unknown transaction record corruption: $corruption"
            ;;
    esac

    inode_before=$(stat -c '%i' "$record_file")
    mapfile -t lines < "$record_file"
    for line in "${lines[@]}"; do
        record_type="${line%%$'\t'*}"
        if [[ "$record_type" == "$target_record" ]]; then
            target_line="$line"
            target_count=$((target_count + 1))
        fi
    done
    if (( target_count != 1 )); then
        fail_test "$record_kind record does not contain one $target_record row"
    fi

    : > "$record_file"
    for line in "${lines[@]}"; do
        record_type="${line%%$'\t'*}"
        if [[ "$record_type" != "$target_record" ]]; then
            printf '%s\n' "$line" >> "$record_file"
            continue
        fi
        case "$corruption" in
            missing)
                ;;
            raw-tab)
                printf '%s\textra\n' "$line" >> "$record_file"
                ;;
            *)
                printf '%s\n' "$line" >> "$record_file"
                ;;
        esac
    done
    case "$corruption" in
        duplicate)
            printf '%s\n' "$target_line" >> "$record_file"
            ;;
        unknown)
            printf 'future-field\tvalue\n' >> "$record_file"
            ;;
    esac
    assert_equal "$inode_before" "$(stat -c '%i' "$record_file")" \
        "$record_kind $corruption corruption replaced the locked record"
}

function exercise_strict_pending_rejection {
    local root="$1"
    local home="$2"
    local xdg_home="$3"
    local state_directory="$4"
    local corruption="$5"
    local label="navigation-recovery-strict-pending-$corruption"
    local pending_file=""
    local snapshot_before=""

    snapshot_before=$(state_snapshot "$state_directory")
    start_gated_runner_outside "$label" "$root" "$home" "$xdg_home" \
        "$RUNNER" m6-strict-pending attach m6-strict-pending
    if ! wait_for_pending_file "$state_directory"; then
        fail_test "$label did not publish a transaction"
    fi
    pending_file="$LAST_PENDING_FILE"
    corrupt_transaction_record "$pending_file" pending "$corruption"
    release_attach_gate
    if ! wait_for_client_session "$root" m6-strict-pending; then
        fail_test "$label did not attach its client"
    fi
    detach_current_client
    finish_current_pty
    ATTACH_GATE_READY=""
    ATTACH_GATE_RELEASE=""
    assert_last_pty_failed_without_timeout "$label unexpectedly succeeded"
    assert_contains "$LAST_TRANSCRIPT" \
        "session entry was not acknowledged: m6-strict-pending" \
        "$label did not report its missing acknowledgment"
    assert_equal "$snapshot_before" "$(state_snapshot "$state_directory")" \
        "$label changed committed state"
    assert_no_state_transactions "$state_directory"
}

function exercise_strict_ack_rejection {
    local root="$1"
    local home="$2"
    local xdg_home="$3"
    local state_directory="$4"
    local corruption="$5"
    local label="navigation-recovery-strict-ack-$corruption"
    local pending_file=""
    local ack_file=""
    local snapshot_before=""

    snapshot_before=$(state_snapshot "$state_directory")
    start_gated_runner_outside "$label" "$root" "$home" "$xdg_home" \
        "$RUNNER" m6-strict-ack attach m6-strict-ack
    if ! wait_for_pending_file "$state_directory"; then
        fail_test "$label did not publish a transaction"
    fi
    pending_file="$LAST_PENDING_FILE"
    ack_file=$(acknowledged_record_for_pending "$pending_file")
    start_state_lock_holder "$label" "$state_directory"
    release_attach_gate
    if ! wait_for_pending_ack "$pending_file"; then
        fail_test "$label did not publish an acknowledgment"
    fi
    corrupt_transaction_record "$ack_file" ack "$corruption"
    stop_state_lock_holder "$label"
    if ! wait_for_client_session "$root" m6-strict-ack; then
        fail_test "$label did not attach its client"
    fi
    detach_current_client
    finish_current_pty
    ATTACH_GATE_READY=""
    ATTACH_GATE_RELEASE=""
    assert_last_pty_succeeded "$label attachment failed"
    assert_equal "$snapshot_before" "$(state_snapshot "$state_directory")" \
        "$label changed committed state"
    assert_no_state_transactions "$state_directory"
}

function exercise_navigation_recovery_strict_transactions {
    local root=""
    local home="$WORKSPACE/navigation-recovery-strict/home"
    local xdg_home="$WORKSPACE/navigation-recovery-strict/xdg"
    local state_home="$WORKSPACE/navigation-recovery-strict/state-home"
    local state_directory=""
    local seed_path="$WORKSPACE/navigation-recovery-strict/seed"
    local pending_path="$WORKSPACE/navigation-recovery-strict/pending"
    local ack_path="$WORKSPACE/navigation-recovery-strict/ack"
    local corruption=""
    local -a corruptions=(missing duplicate unknown raw-tab)

    create_tmux_root navigation-recovery-strict
    root="$NEW_TMUX_ROOT"
    export XDG_STATE_HOME="$state_home"
    state_directory=$(runner_state_directory_for "$state_home")
    mkdir -p -- "$home" "$xdg_home" "$seed_path" "$pending_path" \
        "$ack_path"
    run_outside_success navigation-recovery-strict-seed "$root" "$home" "$xdg_home" \
        "$RUNNER" m6-strict-seed create -s m6-strict-seed -c "$seed_path"
    run_tmux "$root" new-session -d -s m6-strict-pending -c "$pending_path"
    run_tmux "$root" set-option -t '=m6-strict-pending:' \
        @tmux-runner-path "$pending_path"
    run_tmux "$root" new-session -d -s m6-strict-ack -c "$ack_path"
    run_tmux "$root" set-option -t '=m6-strict-ack:' \
        @tmux-runner-path "$ack_path"

    for corruption in "${corruptions[@]}"; do
        exercise_strict_pending_rejection "$root" "$home" "$xdg_home" \
            "$state_directory" "$corruption"
        exercise_strict_ack_rejection "$root" "$home" "$xdg_home" \
            "$state_directory" "$corruption"
    done
    unset XDG_STATE_HOME
}

function test_navigation_recovery {
    exercise_navigation_recovery_data_failures
    exercise_navigation_recovery_lock_timeout
    exercise_navigation_recovery_post_handoff_lock
    exercise_navigation_recovery_transactions
    exercise_navigation_recovery_strict_transactions
    pass_test NAVIGATION-RECOVERY \
        "state failures, acknowledgment ordering, rollback, and orphan recovery"
}

function test_navigation_concurrency {
    local root=""
    local home="$WORKSPACE/navigation-concurrency/home"
    local xdg_home="$WORKSPACE/navigation-concurrency/xdg"
    local state_home="$WORKSPACE/navigation-concurrency/state-home"
    local state_directory=""
    local state_file=""
    local concurrent_root="$WORKSPACE/navigation-concurrency/concurrent"
    local overflow_root="$WORKSPACE/navigation-concurrency/overflow"
    local session_name=""
    local path=""
    local suffix=""
    local expected_paths=""
    local actual_paths=""
    local expected_sessions=""
    local noncanonical_state="$WORKSPACE/navigation-concurrency/noncanonical-state"
    local index=0
    local hook_name=""
    local target_id=""
    local -a concurrent_sessions=()
    local -a concurrent_paths=()
    local -a overflow_paths=()
    local -A entry_hook_names=()

    create_tmux_root navigation-concurrency
    root="$NEW_TMUX_ROOT"
    export XDG_STATE_HOME="$state_home"
    state_directory=$(runner_state_directory_for "$state_home")
    state_file="$state_directory/state"
    mkdir -p -- "$home" "$xdg_home" "$concurrent_root" "$overflow_root"

    for ((index = 1; index <= 8; index++)); do
        printf -v suffix '%02d' "$index"
        session_name="m6-concurrent-$suffix"
        path="$concurrent_root/path-$suffix"
        concurrent_sessions+=("$session_name")
        concurrent_paths+=("$path")
        mkdir -p -- "$path"
        if (( index == 1 )); then
            run_tmux "$root" -f /dev/null new-session -d \
                -s "$session_name" -c "$path"
        else
            run_tmux "$root" new-session -d -s "$session_name" -c "$path"
        fi
        run_tmux "$root" set-option -t "=$session_name:" \
            @tmux-runner-path "$path"
    done

    start_state_record_monitor navigation-concurrency "$root" "$home" "$xdg_home" \
        "$state_home"
    start_concurrent_state_entries navigation-concurrency "$root" "$home" "$xdg_home" \
        "$RUNNER" "${concurrent_sessions[@]}"
    if ! wait_for_state_row_count "$state_file" recent 8; then
        fail_test "concurrent updates did not retain every successful path"
    fi
    if ! validate_main_state_record "$state_file"; then
        fail_test "concurrent updates left an invalid main state record"
    fi
    cp -p -- "$state_file" "$noncanonical_state"
    printf 'applied\t1\n' >> "$noncanonical_state"
    if validate_main_state_record "$noncanonical_state"; then
        fail_test "canonical validator accepted an unowned applied row"
    fi
    expected_paths=$(printf '%s\n' "${concurrent_paths[@]}" | \
        while IFS= read -r path; do encode_state_field "$path"; done | \
        LC_ALL=C sort)
    actual_paths=$(state_record_values recent "$state_file" | LC_ALL=C sort)
    assert_equal "$expected_paths" "$actual_paths" \
        "concurrent updates lost or duplicated a recent path"
    finish_concurrent_state_entries navigation-concurrency "$root"
    for ((index = 1; index <= ${#concurrent_sessions[@]}; index++)); do
        if ! hook_name=$(entry_hook_name_from_trace \
                "$WORKSPACE/pty/navigation-concurrency-$index.typescript"); then
            fail_test "concurrent entry omitted its transaction hook"
        fi
        if [[ -n "${entry_hook_names[$hook_name]:-}" ]]; then
            fail_test "concurrent entries reused a transaction hook"
        fi
        entry_hook_names[$hook_name]=1
        target_id=$(session_id "$root" \
            "${concurrent_sessions[index - 1]}")
        assert_entry_command_targets_id \
            "$WORKSPACE/pty/navigation-concurrency-$index.typescript" "$target_id" \
            "concurrent entry did not target its resolved session ID"
        assert_session_entry_hook_trace \
            "$WORKSPACE/pty/navigation-concurrency-$index.typescript" "$root" \
            "concurrent entry hook did not match or clean its transaction"
    done

    for ((index = 1; index <= 21; index++)); do
        printf -v suffix '%02d' "$index"
        path="$overflow_root/path-$suffix"
        overflow_paths+=("$path")
        mkdir -p -- "$path"
        run_outside_success "navigation-concurrency-overflow-$suffix" "$root" "$home" \
            "$xdg_home" "$RUNNER" "m6-overflow-$suffix" create \
            -s "m6-overflow-$suffix" -c "$path"
    done
    expected_paths=""
    for ((index = 20; index >= 1; index--)); do
        if [[ -n "$expected_paths" ]]; then
            expected_paths+=$'\n'
        fi
        expected_paths+="$(encode_state_field "${overflow_paths[$index]}")"
    done
    actual_paths=$(state_record_values recent "$state_file")
    stop_state_record_monitor navigation-concurrency
    assert_equal "$expected_paths" "$actual_paths" \
        "ordered overflow did not retain exactly the newest 20 paths"
    expected_sessions=$(printf '%s\n%s\n' \
        "$(encode_state_field m6-overflow-21)" \
        "$(encode_state_field m6-overflow-20)")
    assert_equal "$expected_sessions" \
        "$(state_record_values session "$state_file")" \
        "concurrent state did not retain the latest distinct session pair"
    if ! validate_main_state_record "$state_file"; then
        fail_test "overflow updates left an invalid main state record"
    fi
    assert_state_modes "$state_directory"
    assert_no_state_transactions "$state_directory"
    unset XDG_STATE_HOME
    exercise_navigation_concurrency_ack_ticket_aba
    pass_test NAVIGATION-CONCURRENCY \
        "concurrent updates, acknowledgment tickets, and ordered overflow"
}

function test_navigation_regression {
    local root=""
    local home="$WORKSPACE/t6/home with space"
    local xdg_home="$WORKSPACE/t6/xdg config with space"
    local installed_runner="$home/.local/bin/tmux-runner"
    local state_directory="$home/.local/state/tmux-runner"
    local path="$WORKSPACE/navigation-regression/installed-path"
    local debris=""

    create_tmux_root navigation-regression
    root="$NEW_TMUX_ROOT"
    unset XDG_STATE_HOME || true
    mkdir -p -- "$path"
    run_outside_success navigation-regression-installed-create "$root" "$home" \
        "$xdg_home" "$installed_runner" m6-installed-path create \
        -s m6-installed-path -c "$path"
    run_recent_selection_success navigation-regression-installed-recent "$root" "$home" \
        "$xdg_home" "$installed_runner" m6-installed-path "$path"
    run_tmux "$root" new-session -d -s m6-installed-second
    run_outside_success navigation-regression-installed-attach "$root" "$home" \
        "$xdg_home" "$installed_runner" m6-installed-second \
        attach m6-installed-second
    run_outside_success navigation-regression-installed-last "$root" "$home" \
        "$xdg_home" "$installed_runner" m6-installed-path last

    assert_state_modes "$state_directory"
    assert_no_state_transactions "$state_directory"
    assert_contains "$README" \
        "\${XDG_STATE_HOME:-\$HOME/.local/state}/tmux-runner" \
        "README omits the navigation state directory"
    assert_contains "$README" "newest 20 distinct" \
        "README omits the bounded recent-path order"
    assert_contains "$README" "mode \`0700\`" \
        "README omits the state directory mode"
    assert_contains "$README" "mode \`0600\`" \
        "README omits the state record mode"
    assert_contains "$README" "complete main record atomically" \
        "README omits atomic state replacement"
    assert_contains "$README" "acknowledged orphan" \
        "README omits acknowledged orphan recovery"
    assert_contains "$README" "unacknowledged orphan" \
        "README omits unacknowledged orphan recovery"

    debris=$(find "$WORKSPACE" -type f \
        \( -name 'pending.*' -o -name 'ack.*' \
        -o -name '.pending.*' -o -name '.ack.*' \
        -o -name '.state.tmp.*' \) -print)
    assert_equal "" "$debris" \
        "regression run left a state transaction or temporary record"
    pass_test NAVIGATION-REGRESSION \
        "installed navigation, interface, documentation, and cleanup regression"
}

function create_legacy_marked_session {
    local root="$1"
    local session_name="$2"
    local session_path="$3"

    run_tmux "$root" new-session -d -s "$session_name" -c "$session_path"
    run_tmux "$root" set-option -t "=$session_name:" \
        @tmux-runner-path "$session_path"
}

function finish_entry_outside_identity_failure {
    local label="$1"
    local root="$2"
    local state_directory="$3"
    local snapshot_before="$4"
    local ack_file="$5"
    local acknowledgment_observed=0

    start_state_lock_holder "$label-ack-observation" "$state_directory"
    release_entry_gate
    if ! wait_for_file "$ENTRY_GATE_DONE"; then
        stop_state_lock_holder "$label-ack-observation"
        fail_test "$label guarded tmux call did not finish"
    fi
    if [[ -e "$ack_file" ]]; then
        acknowledgment_observed=1
    fi
    stop_state_lock_holder "$label-ack-observation"
    if (( acknowledgment_observed )); then
        fail_test "$label published an acknowledgment"
    fi
    finish_current_pty
    ENTRY_GATE_READY=""
    ENTRY_GATE_RELEASE=""
    ENTRY_GATE_DONE=""
    assert_last_pty_failed_without_timeout "$label identity guard"
    assert_equal "" "$(current_client_sessions "$root")" \
        "$label created a tmux client"
    [[ ! -e "$ack_file" ]] || fail_test "$label retained an acknowledgment"
    if ! wait_for_no_state_transactions "$state_directory"; then
        fail_test "$label did not remove its transaction"
    fi
    assert_equal "$snapshot_before" "$(state_snapshot "$state_directory")" \
        "$label changed navigation state"
    assert_no_session_entry_hooks "$root" \
        "$label left a temporary entry hook"
}

function exercise_entry_unmarked_marker_normalization {
    local root="$1"
    local home="$2"
    local xdg_home="$3"
    local state_directory="$4"
    local conflict_path="$5"
    local state_file="$state_directory/state"
    local session_name="entry-unmarked"
    local target_id=""
    local pending_file=""
    local ack_file=""
    local snapshot_before=""
    local after_set_option_hook=""

    run_tmux "$root" -f /dev/null new-session -d -s "$session_name"
    target_id=$(session_id "$root" "$session_name")
    start_entry_gated_runner_outside entry-unmarked-normalize "$root" \
        "$home" "$xdg_home" "$RUNNER" set-option attach "$session_name"
    if ! wait_for_file "$ENTRY_GATE_READY"; then
        fail_test "unmarked normalization did not reach its barrier"
    fi
    run_tmux "$root" set-option -t "${target_id}:" \
        @tmux-runner-path "$SESSION_PATH_UNMARKED_MARKER"
    release_entry_gate
    if ! wait_for_client_session "$root" "$session_name"; then
        fail_test "concurrent unmarked normalization did not attach"
    fi
    detach_current_client
    finish_current_pty
    ENTRY_GATE_READY=""
    ENTRY_GATE_RELEASE=""
    ENTRY_GATE_DONE=""
    assert_last_pty_succeeded "concurrent unmarked normalization failed"
    assert_session_entry_trace "$LAST_TRANSCRIPT" "$root" "$session_name" \
        "concurrent unmarked normalization did not use its resolved ID"
    assert_equal "$SESSION_PATH_UNMARKED_MARKER" \
        "$(raw_session_path_marker "$root" "$session_name")" \
        "unmarked normalization did not retain its reserved marker"
    assert_equal "" "$(state_record_values recent "$state_file")" \
        "reserved unmarked normalization created a recent path"
    assert_no_state_transactions "$state_directory"
    run_outside_failure entry-unmarked-explicit-conflict "$root" "$home" \
        "$xdg_home" "$RUNNER" create -s "$session_name" -c "$conflict_path"
    assert_contains "$LAST_TRANSCRIPT" \
        "session $session_name exists without @tmux-runner-path" \
        "reserved unmarked session did not retain direct-attach guidance"

    snapshot_before=$(state_snapshot "$state_directory")
    start_entry_gated_runner_outside entry-unmarked-disappear "$root" \
        "$home" "$xdg_home" "$RUNNER" if-shell attach "$session_name"
    if ! wait_for_file "$ENTRY_GATE_READY" || \
        ! wait_for_pending_file "$state_directory"; then
        fail_test "unmarked disappearance did not reach its entry barrier"
    fi
    pending_file="$LAST_PENDING_FILE"
    ack_file=$(acknowledged_record_for_pending "$pending_file")
    run_tmux "$root" set-option -g \
        @tmux-runner-path "$SESSION_PATH_UNMARKED_MARKER"
    run_tmux "$root" set-option -u -t "${target_id}:" \
        @tmux-runner-path
    after_set_option_hook="set-option -g $AFTER_SET_OPTION_SENTINEL yes ; "
    after_set_option_hook+="set-option -g @tmux-runner-path "
    after_set_option_hook+="$SESSION_PATH_UNMARKED_MARKER"
    run_tmux "$root" set-hook -g after-set-option \
        "$after_set_option_hook"
    finish_entry_outside_identity_failure entry-unmarked-disappear "$root" \
        "$state_directory" "$snapshot_before" "$ack_file"
    assert_contains "$LAST_TRANSCRIPT" \
        "session entry was not acknowledged: $session_name" \
        "unmarked disappearance did not report its missing acknowledgment"
    assert_equal "$SESSION_PATH_GLOBAL_FALLBACK_MARKER" \
        "$(run_tmux "$root" show-options -gv @tmux-runner-path)" \
        "entry guard did not replace the colliding global marker"
    assert_equal "" \
        "$(run_tmux "$root" show-options -gqv \
            "$AFTER_SET_OPTION_SENTINEL")" \
        "entry hook allowed after-set-option to interpose"
    assert_entry_command_targets_id "$LAST_TRANSCRIPT" "$target_id" \
        "unmarked disappearance did not target the selected session ID"
    assert_session_entry_hook_trace "$LAST_TRANSCRIPT" "$root" \
        "unmarked disappearance hook did not match or clean its transaction"
    run_tmux "$root" set-hook -gu after-set-option
}

function exercise_entry_outside_identity_guard {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local state_directory="$5"
    local session_name="$6"
    local session_path="$7"
    local mutation="$8"
    local old_id=""
    local new_id=""
    local old_marker=""
    local new_marker=""
    local pending_file=""
    local ack_file=""
    local snapshot_before=""
    local renamed_session="${session_name}-renamed"

    if [[ "$mutation" == "marker" ]]; then
        run_outside_success "$label-seed" "$root" "$home" "$xdg_home" \
            "$RUNNER" "$session_name" create -s "$session_name" \
            -c "$session_path"
    else
        create_legacy_marked_session "$root" "$session_name" "$session_path"
        run_outside_success "$label-seed" "$root" "$home" "$xdg_home" \
            "$RUNNER" "$session_name" attach "$session_name"
    fi
    old_id=$(session_id "$root" "$session_name")
    old_marker=$(raw_session_path_marker "$root" "$session_name")
    if [[ "$mutation" == "marker" ]] && [[ "$old_marker" != v1:* ]]; then
        fail_test "$label runner seed did not write a v1 marker"
    fi
    snapshot_before=$(state_snapshot "$state_directory")

    start_entry_gated_runner_outside "$label" "$root" "$home" \
        "$xdg_home" "$RUNNER" if-shell attach "$session_name"
    if ! wait_for_file "$ENTRY_GATE_READY" || \
        ! wait_for_pending_file "$state_directory"; then
        fail_test "$label did not reach the final entry barrier"
    fi
    pending_file="$LAST_PENDING_FILE"
    ack_file=$(acknowledged_record_for_pending "$pending_file")

    case "$mutation" in
        replace)
            run_tmux "$root" kill-session -t "$old_id"
            create_legacy_marked_session "$root" "$session_name" \
                "$session_path"
            new_id=$(session_id "$root" "$session_name")
            assert_not_equal "$old_id" "$new_id" \
                "$label replacement retained the selected session ID"
            assert_equal "$old_marker" \
                "$(raw_session_path_marker "$root" "$session_name")" \
                "$label replacement changed the raw marker"
            ;;
        marker)
            new_marker="$session_path"
            run_tmux "$root" set-option -t "$old_id:" \
                @tmux-runner-path "$new_marker"
            assert_equal "$old_id" "$(session_id "$root" "$session_name")" \
                "$label marker change replaced the selected session"
            assert_not_equal "$old_marker" \
                "$(raw_session_path_marker "$root" "$session_name")" \
                "$label marker change retained the raw marker"
            assert_equal "$session_path" \
                "$(raw_session_path_marker "$root" "$session_name")" \
                "$label marker change did not use the same legacy path"
            ;;
        rename)
            run_tmux "$root" rename-session -t "$old_id" "$renamed_session"
            assert_equal "$old_id" \
                "$(session_id "$root" "$renamed_session")" \
                "$label rename replaced the selected session"
            assert_equal "$old_marker" \
                "$(raw_session_path_marker "$root" "$renamed_session")" \
                "$label rename changed the raw marker"
            ;;
        *)
            fail_test "$label has an unknown identity mutation"
            ;;
    esac
    finish_entry_outside_identity_failure "$label" "$root" \
        "$state_directory" "$snapshot_before" "$ack_file"
    if [[ "$mutation" != "replace" ]]; then
        assert_contains "$LAST_TRANSCRIPT" \
            "session entry was not acknowledged: $label" \
            "$label did not report its missing acknowledgment"
    fi
}

function exercise_entry_inside_id_replacement {
    local root="$1"
    local home="$2"
    local xdg_home="$3"
    local state_directory="$4"
    local source_session="entry-id-inside-source"
    local target_session="entry-id-inside-target"
    local session_path="$5"
    local old_id=""
    local new_id=""
    local old_marker=""
    local pending_file=""
    local ack_file=""
    local snapshot_before=""
    local status=""
    local acknowledgment_observed=0

    create_legacy_marked_session "$root" "$source_session" "$session_path"
    create_legacy_marked_session "$root" "$target_session" "$session_path"
    run_outside_success entry-id-inside-seed "$root" "$home" "$xdg_home" \
        "$RUNNER" "$target_session" attach "$target_session"
    old_id=$(session_id "$root" "$target_session")
    old_marker=$(raw_session_path_marker "$root" "$target_session")
    snapshot_before=$(state_snapshot "$state_directory")

    start_source_client entry-id-inside "$root" "$home" "$xdg_home" \
        "$source_session"
    invoke_runner_inside_entry_gated entry-id-inside "$root" "$home" \
        "$xdg_home" "$source_session" "$RUNNER" attach "$target_session"
    if ! wait_for_file "$ENTRY_GATE_READY" || \
        ! wait_for_pending_file "$state_directory"; then
        fail_test "inside ID replacement did not reach its entry barrier"
    fi
    pending_file="$LAST_PENDING_FILE"
    ack_file=$(acknowledged_record_for_pending "$pending_file")
    run_tmux "$root" kill-session -t "$old_id"
    create_legacy_marked_session "$root" "$target_session" "$session_path"
    new_id=$(session_id "$root" "$target_session")
    assert_not_equal "$old_id" "$new_id" \
        "inside replacement retained the selected session ID"
    assert_equal "$old_marker" \
        "$(raw_session_path_marker "$root" "$target_session")" \
        "inside replacement changed the raw marker"

    start_state_lock_holder entry-id-inside-ack "$state_directory"
    release_entry_gate
    if ! wait_for_file "$ENTRY_GATE_DONE"; then
        stop_state_lock_holder entry-id-inside-ack
        fail_test "inside ID replacement tmux call did not finish"
    fi
    if [[ -e "$ack_file" ]]; then
        acknowledgment_observed=1
    fi
    stop_state_lock_holder entry-id-inside-ack
    if (( acknowledgment_observed )); then
        fail_test "inside ID replacement published an acknowledgment"
    fi
    if ! wait_for_file "$LAST_INSIDE_STATUS"; then
        fail_test "inside ID replacement did not record runner status"
    fi
    status=$(inside_runner_status)
    assert_not_equal "0" "$status" \
        "inside ID replacement unexpectedly switched clients"
    assert_equal "$source_session" "$(current_client_sessions "$root")" \
        "inside ID replacement moved the existing client"
    [[ ! -e "$ack_file" ]] || \
        fail_test "inside ID replacement retained an acknowledgment"
    if ! wait_for_no_state_transactions "$state_directory"; then
        fail_test "inside ID replacement did not remove its transaction"
    fi
    assert_equal "$snapshot_before" "$(state_snapshot "$state_directory")" \
        "inside ID replacement changed navigation state"
    ENTRY_GATE_READY=""
    ENTRY_GATE_RELEASE=""
    ENTRY_GATE_DONE=""
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "inside ID replacement source client failed"
}

function exercise_entry_special_marker_positive {
    local root="$1"
    local home="$2"
    local xdg_home="$3"
    local state_directory="$4"
    local source_session="m7-special-source"
    local target_session="m7-special"
    local status=""

    start_entry_gated_runner_outside m7-special-outside "$root" "$home" \
        "$xdg_home" "$RUNNER" if-shell attach "$target_session"
    if ! wait_for_file "$ENTRY_GATE_READY" || \
        ! wait_for_pending_file "$state_directory"; then
        fail_test "special-marker outside entry did not reach its barrier"
    fi
    release_entry_gate
    if ! wait_for_client_session "$root" "$target_session"; then
        fail_test "special-marker outside entry did not attach"
    fi
    detach_current_client
    finish_current_pty
    ENTRY_GATE_READY=""
    ENTRY_GATE_RELEASE=""
    ENTRY_GATE_DONE=""
    assert_last_pty_succeeded "special-marker outside entry failed"

    start_source_client m7-special-inside "$root" "$home" "$xdg_home" \
        "$source_session"
    invoke_runner_inside_entry_gated m7-special-inside "$root" "$home" \
        "$xdg_home" "$source_session" "$RUNNER" attach "$target_session"
    if ! wait_for_file "$ENTRY_GATE_READY" || \
        ! wait_for_pending_file "$state_directory"; then
        fail_test "special-marker inside entry did not reach its barrier"
    fi
    release_entry_gate
    if ! wait_for_client_session "$root" "$target_session" || \
        ! wait_for_file "$LAST_INSIDE_STATUS"; then
        fail_test "special-marker inside entry did not switch"
    fi
    status=$(inside_runner_status)
    assert_equal "0" "$status" "special-marker inside entry failed"
    ENTRY_GATE_READY=""
    ENTRY_GATE_RELEASE=""
    ENTRY_GATE_DONE=""
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "special-marker inside source client failed"
    assert_no_state_transactions "$state_directory"
}

function exercise_entry_session_identity {
    local root=""
    local home="$WORKSPACE/entry-identity/home"
    local xdg_home="$WORKSPACE/entry-identity/config"
    local state_home="$WORKSPACE/entry-identity/state-home"
    local state_directory=""
    local special_path="$WORKSPACE/entry-identity/path-#,};'"
    local replace_path="$WORKSPACE/entry-identity/replace-#,}"
    local marker_path="$WORKSPACE/entry-identity/marker-#,}"
    local rename_path="$WORKSPACE/entry-identity/rename-#,}"
    local inside_path="$WORKSPACE/entry-identity/inside-#,}"
    local unmarked_conflict_path="$WORKSPACE/entry-identity/unmarked-conflict"

    create_tmux_root entry-identity
    root="$NEW_TMUX_ROOT"
    export XDG_STATE_HOME="$state_home"
    state_directory=$(runner_state_directory_for "$state_home")
    mkdir -p -- "$home" "$xdg_home" "$special_path" "$replace_path" \
        "$marker_path" "$rename_path" "$inside_path" \
        "$unmarked_conflict_path"

    exercise_entry_unmarked_marker_normalization "$root" "$home" \
        "$xdg_home" "$state_directory" "$unmarked_conflict_path"

    create_legacy_marked_session "$root" m7-special "$special_path"
    run_tmux "$root" new-session -d -s m7-special-source
    exercise_entry_special_marker_positive "$root" "$home" "$xdg_home" \
        "$state_directory"

    exercise_entry_outside_identity_guard entry-id-replace "$root" "$home" \
        "$xdg_home" "$state_directory" entry-id-replace "$replace_path" \
        replace
    exercise_entry_outside_identity_guard entry-marker-change "$root" "$home" \
        "$xdg_home" "$state_directory" entry-marker-change "$marker_path" \
        marker
    exercise_entry_outside_identity_guard entry-name-change "$root" "$home" \
        "$xdg_home" "$state_directory" entry-name-change "$rename_path" \
        rename
    exercise_entry_inside_id_replacement "$root" "$home" "$xdg_home" \
        "$state_directory" "$inside_path"
    assert_no_state_transactions "$state_directory"
    unset XDG_STATE_HOME
}

function test_installation_bundle {
    local root=""
    local home="$WORKSPACE/installation-bundle/home with space"
    local xdg_home="$WORKSPACE/installation-bundle/config home with space"
    local installed_runner="$home/.local/bin/tmux-runner"
    local installed_completion="$home/.local/share/bash-completion/completions/tmux-runner"
    local installed_config="$xdg_home/tmux-runner/tmux.conf"
    local preserved_config="$WORKSPACE/installation-bundle/preserved-tmux.conf"
    local session_path="$WORKSPACE/installation-bundle/session path"
    local state_directory="$home/.local/state/tmux-runner"
    local ambient_repository="$WORKSPACE/installation-bundle/ambient-repository"
    local no_git_source="$WORKSPACE/installation-bundle/no-git-source"
    local unrelated_home="$WORKSPACE/installation-bundle/unrelated-home"
    local no_git_xdg="$WORKSPACE/installation-bundle/no-git-config"
    local no_git_runner="$unrelated_home/.local/bin/tmux-runner"
    local no_git_version=""
    local no_git_install_date=""
    local no_git_install_epoch=0
    local install_before=0
    local install_after=0
    local unrelated_hash=""
    local inventory=""
    local expected_inventory=""
    local socket_file=""

    unset XDG_STATE_HOME || true
    create_tmux_root installation-bundle
    root="$NEW_TMUX_ROOT"
    mkdir -p -- "$home" "$xdg_home" "$session_path"
    init_git_repository "$ambient_repository"
    assert_command_succeeds "INSTALLATION-BUNDLE make install failed" \
        env GIT_DIR="$ambient_repository/.git" \
        GIT_WORK_TREE="$ambient_repository" XDG_CONFIG_HOME="$xdg_home" \
        make -C "$REPO_ROOT" HOME="$home" install

    inventory=$(find "$home" "$xdg_home" \( -type f -o -type l \) \
        -print | LC_ALL=C sort)
    expected_inventory=$(printf '%s\n%s\n%s\n' \
        "$installed_runner" "$installed_completion" "$installed_config" | \
        LC_ALL=C sort)
    assert_equal "$expected_inventory" "$inventory" \
        "INSTALLATION-BUNDLE install inventory is wrong"
    assert_equal "0755" "0$(stat -c '%a' "$installed_runner")" \
        "INSTALLATION-BUNDLE installed runner mode is wrong"
    assert_equal "0644" "0$(stat -c '%a' "$installed_completion")" \
        "INSTALLATION-BUNDLE installed completion mode is wrong"
    assert_equal "0644" "0$(stat -c '%a' "$installed_config")" \
        "INSTALLATION-BUNDLE installed config mode is wrong"
    assert_command_succeeds "INSTALLATION-BUNDLE initial config differs from source" \
        cmp -s "$RUNNER_CONFIG" "$installed_config"

    printf '%s\n' 'set -g @tmux-runner-m7-config loaded' > "$installed_config"
    cp "$installed_config" "$preserved_config"
    assert_command_succeeds "INSTALLATION-BUNDLE second make install failed" \
        env GIT_DIR="$ambient_repository/.git" \
        GIT_WORK_TREE="$ambient_repository" XDG_CONFIG_HOME="$xdg_home" \
        make -C "$REPO_ROOT" HOME="$home" install
    assert_command_succeeds "INSTALLATION-BUNDLE second install changed local config" \
        cmp -s "$preserved_config" "$installed_config"

    mkdir -p -- "$no_git_source" "$no_git_xdg"
    cp -- "$REPO_ROOT/Makefile" "$no_git_source/Makefile"
    cp -a -- "$REPO_ROOT/bin" "$REPO_ROOT/config" \
        "$REPO_ROOT/configure" "$no_git_source/"
    if git -C "$no_git_source" rev-parse --is-inside-work-tree \
            >/dev/null 2>&1; then
        fail_test "INSTALLATION-BUNDLE plain source copy unexpectedly has Git identity"
    fi
    init_git_repository "$unrelated_home"
    unrelated_hash=$(git -C "$unrelated_home" rev-parse --short HEAD)
    install_before=$(date -u '+%s')
    assert_command_succeeds "INSTALLATION-BUNDLE no-Git source install failed" \
        env GIT_DIR="$unrelated_home/.git" \
        GIT_WORK_TREE="$unrelated_home" XDG_CONFIG_HOME="$no_git_xdg" \
        make -C "$no_git_source" HOME="$unrelated_home" install
    install_after=$(date -u '+%s')
    no_git_version=$(cd -- "$unrelated_home" && \
        "$no_git_runner" --version)
    assert_equal "tmux-runner version 0.1.0 (unknown)" \
        "${no_git_version%%$'\n'*}" \
        "INSTALLATION-BUNDLE no-Git installation adopted another repository"
    assert_equal "unknown" \
        "$(printf '%s\n' "$no_git_version" | \
            sed -n 's/^commit date:  //p')" \
        "INSTALLATION-BUNDLE no-Git installation reported a commit date"
    no_git_install_date=$(printf '%s\n' "$no_git_version" | \
        sed -n 's/^install date: //p')
    if [[ ! "$no_git_install_date" =~ \
        ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        fail_test "INSTALLATION-BUNDLE no-Git installation date is not UTC"
    fi
    if ! no_git_install_epoch=$(date -u -d "$no_git_install_date" '+%s'); then
        fail_test "INSTALLATION-BUNDLE no-Git installation date is not parseable UTC"
    fi
    if (( no_git_install_epoch < install_before || \
        no_git_install_epoch > install_after )); then
        fail_test "INSTALLATION-BUNDLE no-Git installation date is outside its interval"
    fi
    assert_text_not_contains "$no_git_version" "(live)" \
        "INSTALLATION-BUNDLE no-Git installation used live metadata"
    assert_text_not_contains "$no_git_version" "$unrelated_hash" \
        "INSTALLATION-BUNDLE no-Git installation used its HOME repository identity"

    socket_file=$(find "$root" -type s -print -quit)
    assert_equal "" "$socket_file" \
        "INSTALLATION-BUNDLE did not begin with a cold tmux root"
    run_outside_success installation-bundle-cold-create "$root" "$home" "$xdg_home" \
        "$installed_runner" m7-install-session create \
        -s m7-install-session -c "$session_path"
    assert_equal "loaded" \
        "$(run_tmux "$root" show-options -gv @tmux-runner-m7-config)" \
        "INSTALLATION-BUNDLE cold server did not load the preserved local config"
    assert_equal "$session_path" \
        "$(pane_directory "$root" m7-install-session)" \
        "INSTALLATION-BUNDLE installed runner started in the wrong directory"
    assert_state_modes "$state_directory"
    assert_no_state_transactions "$state_directory"
    pass_test INSTALLATION-BUNDLE \
        "spaced installation, preservation, and cold config startup"
}

function test_interface_bundle {
    local root=""
    local home="$WORKSPACE/interface-bundle/home"
    local xdg_home="$WORKSPACE/interface-bundle/config"
    local stdout_file=""
    local stderr_file=""
    local short_version=""
    local long_version=""
    local command_name=""
    local -a command_names=(create c repo recent last ls attach a)

    create_tmux_root interface-bundle
    root="$NEW_TMUX_ROOT"
    mkdir -p -- "$home" "$xdg_home" "$WORKSPACE/interface-bundle/help"
    run_tmux "$root" -f /dev/null new-session -d -s interface-bundle

    for command_name in "${command_names[@]}"; do
        stdout_file="$WORKSPACE/interface-bundle/help/$command_name.stdout"
        stderr_file="$WORKSPACE/interface-bundle/help/$command_name.stderr"
        assert_command_succeeds "$command_name --help failed" \
            env PATH=/nonexistent /bin/bash "$RUNNER" \
            "$command_name" --help > "$stdout_file" 2> "$stderr_file"
        assert_contains "$stdout_file" "Usage: tmux-runner $command_name" \
            "$command_name help omitted its usage"
        if [[ -s "$stderr_file" ]]; then
            fail_test "$command_name help wrote to stderr"
        fi
    done
    assert_command_succeeds "top-level help failed" \
        env PATH=/nonexistent /bin/bash "$RUNNER" --help \
        > "$WORKSPACE/interface-bundle/help/top.stdout" \
        2> "$WORKSPACE/interface-bundle/help/top.stderr"
    assert_contains "$WORKSPACE/interface-bundle/help/top.stdout" \
        "Default-server sessions are not migrated or visible" \
        "top-level help omits default-server isolation"
    short_version=$(env PATH=/nonexistent /bin/bash "$RUNNER" -V)
    long_version=$(env PATH=/nonexistent /bin/bash "$RUNNER" --version)
    assert_equal "$short_version" "$long_version" \
        "INTERFACE-BUNDLE version aliases differ"

    unset TMUX || true
    export TMUX_TMPDIR="$root"
    # The active completion copy must describe the active runner copy.
    # shellcheck disable=SC1090,SC1091
    source "$COMPLETION"
    COMP_WORDS=(tmux-runner "")
    COMP_CWORD=1
    _tmux_runner
    assert_reply_set "INTERFACE-BUNDLE command completion set is wrong" \
        create c repo recent last ls attach a -V --version -h --help
    COMP_WORDS=(tmux-runner attach -)
    COMP_CWORD=2
    _tmux_runner
    assert_reply_set "INTERFACE-BUNDLE attach option completion set is wrong" \
        -t -- -h --help
    COMP_WORDS=(tmux-runner a -)
    COMP_CWORD=2
    _tmux_runner
    assert_reply_set "INTERFACE-BUNDLE a option completion set is wrong" \
        -t -- -h --help
    COMP_WORDS=(tmux-runner attach -- interface)
    COMP_CWORD=3
    _tmux_runner
    assert_reply_set "INTERFACE-BUNDLE terminator completion set is wrong" interface-bundle

    assert_contains "$README" "Existing default-server sessions are not" \
        "README omits default-server isolation"
    assert_contains "$README" "detach and rerun" \
        "README omits the cross-server detach instruction"
    assert_contains "$README" "tmux-runner attach --" \
        "README omits valid attach terminator syntax"
    assert_contains "$README" "tmux-runner/tmux.conf" \
        "README omits the local config path"
    assert_contains "$README" ".local/state}/tmux-runner" \
        "README omits the local state path"
    assert_contains "$README" "source ~/.local/share/bash-completion" \
        "README omits completion activation"
    assert_contains "$README" \
        $'`create`, `repo`, and `recent` require\nGit to validate working-tree identity.' \
        "README omits the Git requirement scope"
    assert_contains "$README" \
        $'Their automatic session names also\nrequire `hostname`;' \
        "README omits the hostname requirement scope"
    assert_contains "$README" \
        $'`repo`, catalog-aware automatic `create`, and catalog-aware `recent` also\nrequire `find` and `sort`.' \
        "README omits the find and sort requirement scope"
    assert_contains "$README" "that server's configured detach binding" \
        "README omits the configured cross-server detach binding"

    run_outside_success interface-bundle-attach-terminator "$root" "$home" \
        "$xdg_home" "$RUNNER" interface-bundle attach -- interface-bundle
    assert_session_entry_trace "$LAST_TRANSCRIPT" "$root" interface-bundle \
        "INTERFACE-BUNDLE valid attach -- did not use the exact session target"
    pass_test INTERFACE-BUNDLE "$TEST_VARIANT help, completion, README, and attach --"
}

function assert_manifest_processes_stopped {
    local manifest="$1"
    local process_id=""

    while IFS= read -r process_id; do
        if [[ -n "$process_id" ]] && kill -0 "$process_id" 2>/dev/null; then
            printf 'Tracked process is still running: %s\n' "$process_id" >&2
            return 1
        fi
    done < <(awk -F '\t' '$1 == "pid" { print $2 }' "$manifest")
}

function manifest_workspace {
    local manifest="$1"

    awk -F '\t' '$1 == "workspace" { print $2; exit }' "$manifest"
}

function manifest_value {
    local manifest="$1"
    local record_type="$2"

    awk -F '\t' -v record_type="$record_type" \
        '$1 == record_type { print $2; exit }' "$manifest"
}

function wait_for_supervisor_file {
    local path="$1"
    local deadline=$((SECONDS + SUPERVISOR_TIMEOUT_SECONDS))

    while (( SECONDS <= deadline )); do
        if [[ -e "$path" ]]; then
            return 0
        fi
        sleep "$POLL_INTERVAL_SECONDS"
    done
    return 1
}

function state_transaction_debris {
    local state_directory="$1"

    find "$state_directory" -maxdepth 1 -type f \
        \( -name 'pending.*' -o -name 'ack.*' \
        -o -name '.pending.*' -o -name '.ack.*' \
        -o -name '.state.tmp.*' \) -print
}

function directory_lock_available {
    local state_directory="$1"
    local lock_fd=""
    local lock_rc=0

    exec {lock_fd}<"$state_directory"
    flock -n -x "$lock_fd" || lock_rc=$?
    if (( lock_rc == 0 )); then
        flock -u "$lock_fd"
    fi
    exec {lock_fd}>&-
    return "$lock_rc"
}

function remove_supervisor_control_files {
    local supervisor_workspace="$1"

    if [[ -d "$supervisor_workspace" ]] && \
        [[ "$supervisor_workspace" == /tmp/tmux-runner-supervisor.* ]]; then
        chmod -R u+w -- "$supervisor_workspace" 2>/dev/null || true
        rm -rf -- "$supervisor_workspace"
    fi
}

function run_complete_child {
    local variant="$1"
    local runner="$2"
    local completion="$3"
    local manifest="$4"
    local ambient_repository="$5"
    local script_path="$TEST_DIR/test-tmux-runner.bash"
    local child_workspace=""
    local child_rc=0

    : > "$manifest"
    env GIT_DIR="$ambient_repository/.git" \
        GIT_WORK_TREE="$ambient_repository" TMUX_RUNNER_TEST_CHILD=1 \
        TMUX_RUNNER_TEST_EXPECTED_AMBIENT_REPOSITORY="$ambient_repository" \
        TMUX_RUNNER_TEST_MANIFEST="$manifest" \
        TMUX_RUNNER_TEST_VARIANT="$variant" \
        TMUX_RUNNER_TEST_RUNNER="$runner" \
        TMUX_RUNNER_TEST_COMPLETION="$completion" \
        bash "$script_path" || child_rc=$?
    child_workspace=$(manifest_workspace "$manifest")
    if (( child_rc != 0 )); then
        printf '%s test child failed with exit %d.\n' \
            "$variant" "$child_rc" >&2
        return "$child_rc"
    fi
    if [[ -z "$child_workspace" ]] || [[ -e "$child_workspace" ]]; then
        printf '%s child left its workspace: %s\n' \
            "$variant" "$child_workspace" >&2
        return 1
    fi
    if ! assert_manifest_processes_stopped "$manifest"; then
        return 1
    fi
}

function stop_observation_child {
    local child_pid="$1"
    local start_release="$2"
    local finish_release="$3"
    local cleanup_done="$4"

    : > "$start_release"
    : > "$finish_release"
    if kill -0 "$child_pid" 2>/dev/null; then
        kill -TERM "$child_pid" 2>/dev/null || true
    fi
    if ! wait_for_supervisor_file "$cleanup_done" && \
        kill -0 "$child_pid" 2>/dev/null; then
        kill -KILL "$child_pid" 2>/dev/null || true
    fi
    wait "$child_pid" 2>/dev/null || true
}

function inspect_observation_before_release {
    local manifest="$1"
    local root=""
    local state_directory=""
    local runner_socket=""
    local default_socket=""

    root=$(manifest_value "$manifest" root)
    state_directory=$(manifest_value "$manifest" state)
    if [[ -z "$root" ]] || [[ -z "$state_directory" ]]; then
        printf 'Observation manifest is incomplete before release.\n' >&2
        return 1
    fi
    runner_socket="$root/tmux-$UID/$RUNNER_SERVER_NAME"
    default_socket="$root/tmux-$UID/default"
    if [[ -e "$runner_socket" ]] || [[ -e "$default_socket" ]]; then
        printf 'Observation probe created a socket before release.\n' >&2
        return 1
    fi
    if [[ -e "$state_directory" ]]; then
        printf 'Observation probe created state before release.\n' >&2
        return 1
    fi
}

function inspect_observation_live {
    local manifest="$1"
    local root=""
    local state_directory=""
    local state_file=""
    local runner_socket=""
    local default_socket=""
    local runner_session=""
    local default_session=""
    local runner_pane_count=""
    local default_pane_count=""
    local client_session=""
    local server_pid=""
    local default_server_pid=""
    local pane_pid=""
    local default_pane_pid=""
    local client_pid=""
    local debris=""
    local process_id=""
    local -a process_ids=()

    root=$(manifest_value "$manifest" root)
    state_directory=$(manifest_value "$manifest" state)
    state_file="$state_directory/state"
    runner_socket="$root/tmux-$UID/$RUNNER_SERVER_NAME"
    default_socket="$root/tmux-$UID/default"
    if [[ ! -S "$runner_socket" ]] || [[ ! -S "$default_socket" ]] || \
        [[ "$runner_socket" == "$default_socket" ]]; then
        printf 'Observation probe did not expose two separate sockets.\n' >&2
        return 1
    fi

    runner_session=$(run_tmux "$root" list-sessions -F '#{session_name}')
    default_session=$(
        run_default_tmux "$root" list-sessions -F '#{session_name}'
    )
    if [[ "$runner_session" != "m7-observation" ]] || \
        [[ "$default_session" != "m7-default-observation" ]]; then
        printf 'Observation probe session isolation is wrong.\n' >&2
        return 1
    fi
    runner_pane_count=$(run_tmux "$root" list-panes -a | wc -l)
    default_pane_count=$(run_default_tmux "$root" list-panes -a | wc -l)
    if [[ "$runner_pane_count" != "1" ]] || \
        [[ "$default_pane_count" != "1" ]]; then
        printf 'Observation probe pane inventory is wrong.\n' >&2
        return 1
    fi
    client_session=$(current_client_sessions "$root")
    if [[ "$client_session" != "m7-observation" ]]; then
        printf 'Observation probe did not expose its live client.\n' >&2
        return 1
    fi

    server_pid=$(run_tmux "$root" display-message -p '#{pid}')
    default_server_pid=$(
        run_default_tmux "$root" display-message -p '#{pid}'
    )
    pane_pid=$(run_tmux "$root" list-panes -a -F '#{pane_pid}')
    default_pane_pid=$(
        run_default_tmux "$root" list-panes -a -F '#{pane_pid}'
    )
    client_pid=$(run_tmux "$root" list-clients -F '#{client_pid}')
    process_ids=(
        "$server_pid" "$default_server_pid" "$pane_pid"
        "$default_pane_pid" "$client_pid"
    )
    for process_id in "${process_ids[@]}"; do
        if [[ ! "$process_id" =~ ^[0-9]+$ ]] || \
            ! kill -0 "$process_id" 2>/dev/null; then
            printf 'Observation process is not live: %s\n' \
                "$process_id" >&2
            return 1
        fi
        printf 'pid\t%s\n' "$process_id" >> "$manifest"
    done

    if [[ ! -s "$state_file" ]] || ! validate_main_state_record "$state_file"; then
        printf 'Observation probe exposed invalid state.\n' >&2
        return 1
    fi
    if [[ "$(stat -c '%a' "$state_directory")" != "700" ]] || \
        [[ "$(stat -c '%a' "$state_file")" != "600" ]]; then
        printf 'Observation probe exposed invalid state modes.\n' >&2
        return 1
    fi
    debris=$(state_transaction_debris "$state_directory")
    if [[ -n "$debris" ]]; then
        printf 'Observation probe exposed transaction debris:\n%s\n' \
            "$debris" >&2
        return 1
    fi
    if directory_lock_available "$state_directory"; then
        printf 'Observation directory lock was not held.\n' >&2
        return 1
    fi
}

function inspect_observation_after_cleanup {
    local manifest="$1"
    local root=""
    local workspace=""
    local state_directory=""

    root=$(manifest_value "$manifest" root)
    workspace=$(manifest_workspace "$manifest")
    state_directory=$(manifest_value "$manifest" state)
    if [[ -z "$workspace" ]] || [[ -e "$workspace" ]]; then
        printf 'Observation child left its workspace: %s\n' \
            "$workspace" >&2
        return 1
    fi
    if [[ -e "$root/tmux-$UID/$RUNNER_SERVER_NAME" ]] || \
        [[ -e "$root/tmux-$UID/default" ]] || [[ -e "$state_directory" ]]; then
        printf 'Observation child left a socket or state path.\n' >&2
        return 1
    fi
    if ! assert_manifest_processes_stopped "$manifest"; then
        return 1
    fi
}

function run_observation_supervisor {
    local supervisor_workspace="$1"
    local variant="$2"
    local runner="$3"
    local ambient_repository="$4"
    local script_path="$TEST_DIR/test-tmux-runner.bash"
    local manifest="$supervisor_workspace/$variant-observation.manifest"
    local pre_ready="$supervisor_workspace/$variant-observation.pre-ready"
    local start_release="$supervisor_workspace/$variant-observation.start-release"
    local live_ready="$supervisor_workspace/$variant-observation.live-ready"
    local finish_release="$supervisor_workspace/$variant-observation.finish-release"
    local cleanup_done="$supervisor_workspace/$variant-observation.cleanup-done"
    local child_pid=""
    local child_rc=0

    : > "$manifest"
    env GIT_DIR="$ambient_repository/.git" \
        GIT_WORK_TREE="$ambient_repository" TMUX_RUNNER_TEST_CHILD=1 \
        TMUX_RUNNER_TEST_OBSERVATION=1 \
        TMUX_RUNNER_TEST_EXPECTED_AMBIENT_REPOSITORY="$ambient_repository" \
        TMUX_RUNNER_TEST_MANIFEST="$manifest" \
        TMUX_RUNNER_TEST_VARIANT="$variant" \
        TMUX_RUNNER_TEST_RUNNER="$runner" \
        TMUX_RUNNER_TEST_PRE_READY="$pre_ready" \
        TMUX_RUNNER_TEST_START_RELEASE="$start_release" \
        TMUX_RUNNER_TEST_LIVE_READY="$live_ready" \
        TMUX_RUNNER_TEST_FINISH_RELEASE="$finish_release" \
        TMUX_RUNNER_TEST_CLEANUP_DONE="$cleanup_done" \
        bash "$script_path" &
    child_pid=$!

    if ! wait_for_supervisor_file "$pre_ready"; then
        printf '%s observation pre-release readiness timed out.\n' \
            "$variant" >&2
        stop_observation_child "$child_pid" "$start_release" \
            "$finish_release" "$cleanup_done"
        return 1
    fi
    if ! inspect_observation_before_release "$manifest"; then
        stop_observation_child "$child_pid" "$start_release" \
            "$finish_release" "$cleanup_done"
        return 1
    fi
    printf 'release\n' > "$start_release"
    if ! wait_for_supervisor_file "$live_ready"; then
        printf '%s observation live readiness timed out.\n' "$variant" >&2
        stop_observation_child "$child_pid" "$start_release" \
            "$finish_release" "$cleanup_done"
        return 1
    fi
    if ! inspect_observation_live "$manifest"; then
        stop_observation_child "$child_pid" "$start_release" \
            "$finish_release" "$cleanup_done"
        return 1
    fi
    printf 'release\n' > "$finish_release"
    if ! wait_for_supervisor_file "$cleanup_done"; then
        printf '%s observation cleanup timed out.\n' "$variant" >&2
        stop_observation_child "$child_pid" "$start_release" \
            "$finish_release" "$cleanup_done"
        return 1
    fi
    wait "$child_pid" || child_rc=$?
    if (( child_rc != 0 )); then
        printf '%s observation failed with exit %d.\n' \
            "$variant" "$child_rc" >&2
        return 1
    fi
    inspect_observation_after_cleanup "$manifest"
}

function run_forced_cleanup_supervisor {
    local supervisor_workspace="$1"
    local variant="$2"
    local runner="$3"
    local ambient_repository="$4"
    local script_path="$TEST_DIR/test-tmux-runner.bash"
    local failure_manifest="$supervisor_workspace/$variant-failure.manifest"
    local failure_output="$supervisor_workspace/$variant-failure.output"
    local failure_workspace=""
    local failure_state_directory=""
    local failure_state_file=""
    local failure_debris=""
    local socket_file=""
    local probe_rc=0

    env GIT_DIR="$ambient_repository/.git" \
        GIT_WORK_TREE="$ambient_repository" TMUX_RUNNER_TEST_CHILD=1 \
        TMUX_RUNNER_TEST_FORCE_FAILURE=1 \
        TMUX_RUNNER_TEST_EXPECTED_AMBIENT_REPOSITORY="$ambient_repository" \
        TMUX_RUNNER_TEST_VARIANT="$variant" \
        TMUX_RUNNER_TEST_RUNNER="$runner" \
        TMUX_RUNNER_TEST_MANIFEST="$failure_manifest" \
        bash "$script_path" > "$failure_output" 2>&1 || probe_rc=$?
    if (( probe_rc == 0 )); then
        printf '%s forced cleanup probe unexpectedly succeeded.\n' \
            "$variant" >&2
        return 1
    fi
    failure_workspace=$(manifest_workspace "$failure_manifest")
    if [[ -z "$failure_workspace" ]] || [[ ! -d "$failure_workspace" ]]; then
        printf '%s forced failure did not preserve its workspace.\n' \
            "$variant" >&2
        return 1
    fi
    if ! grep -F -- "Diagnostic workspace: $failure_workspace" \
        "$failure_output" >/dev/null; then
        printf '%s forced failure did not report its workspace.\n' \
            "$variant" >&2
        return 1
    fi
    if ! assert_manifest_processes_stopped "$failure_manifest"; then
        return 1
    fi
    failure_state_directory=$(manifest_value "$failure_manifest" state)
    failure_state_file="$failure_state_directory/state"
    if [[ ! -s "$failure_state_file" ]] || \
        ! validate_main_state_record "$failure_state_file"; then
        printf '%s forced failure did not preserve valid state.\n' \
            "$variant" >&2
        return 1
    fi
    failure_debris=$(state_transaction_debris "$failure_state_directory")
    if [[ -n "$failure_debris" ]]; then
        printf '%s forced failure left transaction debris:\n%s\n' \
            "$variant" "$failure_debris" >&2
        return 1
    fi
    if ! directory_lock_available "$failure_state_directory"; then
        printf '%s forced failure did not release the state directory lock.\n' \
            "$variant" >&2
        return 1
    fi
    socket_file=$(find "$failure_workspace" -type s -print -quit)
    if [[ -n "$socket_file" ]]; then
        printf '%s forced failure left a socket: %s\n' \
            "$variant" "$socket_file" >&2
        return 1
    fi

    chmod -R u+w -- "$failure_workspace"
    rm -rf -- "$failure_workspace"
}

function run_forced_cleanup_probe {
    local root=""
    local home=""
    local xdg_home=""
    local state_directory=""
    local state_file=""
    local session_path=""
    local probe_pid=""

    require_dependencies
    unset XDG_STATE_HOME || true
    WORKSPACE=$(mktemp -d /tmp/tmux-runner-test.XXXXXX)
    record_manifest workspace "$WORKSPACE"
    mkdir -p -- "$WORKSPACE/pty"
    create_tmux_root cleanup-probe
    root="$NEW_TMUX_ROOT"
    home="$WORKSPACE/cleanup-probe/home"
    xdg_home="$WORKSPACE/cleanup-probe/config"
    session_path="$WORKSPACE/cleanup-probe/session"
    state_directory="$home/.local/state/tmux-runner"
    state_file="$state_directory/state"
    mkdir -p -- "$home" "$xdg_home" "$session_path"
    record_manifest state "$state_directory"
    run_outside_success cleanup-probe-state "$root" "$home" "$xdg_home" \
        "$RUNNER" cleanup-probe create -s cleanup-probe -c "$session_path"
    if [[ ! -s "$state_file" ]] || ! validate_main_state_record "$state_file"; then
        fail_test "forced cleanup probe did not create valid state"
    fi
    assert_no_state_transactions "$state_directory"
    run_default_tmux "$root" -f /dev/null new-session -d \
        -s cleanup-default
    start_state_lock_holder cleanup-probe "$state_directory"
    setsid sleep 60 &
    probe_pid=$!
    EXTRA_PTY_PIDS+=("$probe_pid")
    record_manifest pid "$probe_pid"
    fail_test "forced cleanup probe"
}

function run_observation_probe {
    local root=""
    local home=""
    local xdg_home=""
    local state_directory=""
    local state_file=""
    local session_path=""
    local pre_ready="${TMUX_RUNNER_TEST_PRE_READY:-}"
    local start_release="${TMUX_RUNNER_TEST_START_RELEASE:-}"
    local live_ready="${TMUX_RUNNER_TEST_LIVE_READY:-}"
    local finish_release="${TMUX_RUNNER_TEST_FINISH_RELEASE:-}"

    require_dependencies
    unset XDG_STATE_HOME || true
    if [[ -z "$pre_ready" ]] || [[ -z "$start_release" ]] || \
        [[ -z "$live_ready" ]] || [[ -z "$finish_release" ]]; then
        fail_test "observation probe control path is missing"
    fi

    WORKSPACE=$(mktemp -d /tmp/tmux-runner-test.XXXXXX)
    record_manifest workspace "$WORKSPACE"
    mkdir -p -- "$WORKSPACE/pty"
    create_tmux_root m7-observation
    root="$NEW_TMUX_ROOT"
    home="$WORKSPACE/m7-observation/home"
    xdg_home="$WORKSPACE/m7-observation/config"
    session_path="$WORKSPACE/m7-observation/session"
    state_directory="$home/.local/state/tmux-runner"
    state_file="$state_directory/state"
    mkdir -p -- "$home" "$xdg_home" "$session_path"
    record_manifest state "$state_directory"
    printf 'ready\n' > "$pre_ready"

    if ! wait_for_supervisor_file "$start_release"; then
        fail_test "observation probe start release timed out"
    fi
    run_outside_success m7-observation-create "$root" "$home" \
        "$xdg_home" "$RUNNER" m7-observation create \
        -s m7-observation -c "$session_path"
    run_default_tmux "$root" -f /dev/null new-session -d \
        -s m7-default-observation
    start_source_client m7-observation "$root" "$home" "$xdg_home" \
        m7-observation
    if [[ ! -s "$state_file" ]] || ! validate_main_state_record "$state_file"; then
        fail_test "observation probe state is invalid"
    fi
    assert_no_state_transactions "$state_directory"
    start_state_lock_holder m7-observation "$state_directory"
    printf 'ready\n' > "$live_ready"

    if ! wait_for_supervisor_file "$finish_release"; then
        fail_test "observation probe finish release timed out"
    fi
    stop_state_lock_holder m7-observation
    detach_current_client
    finish_current_pty
    assert_last_pty_succeeded "observation probe client failed"
}

function run_supervisor {
    local supervisor_workspace=""
    local source_manifest=""
    local installed_manifest=""
    local install_home=""
    local install_config_home=""
    local installed_runner=""
    local installed_completion=""
    local ambient_repository=""

    supervisor_workspace=$(mktemp -d /tmp/tmux-runner-supervisor.XXXXXX)
    source_manifest="$supervisor_workspace/source.manifest"
    installed_manifest="$supervisor_workspace/installed.manifest"
    install_home="$supervisor_workspace/installed home"
    install_config_home="$supervisor_workspace/installed config"
    installed_runner="$install_home/.local/bin/tmux-runner"
    installed_completion="$install_home/.local/share/bash-completion/completions/tmux-runner"
    ambient_repository="$supervisor_workspace/ambient-repository"
    init_git_repository "$ambient_repository"

    if ! run_complete_child source "$SOURCE_RUNNER" "$SOURCE_COMPLETION" \
        "$source_manifest" "$ambient_repository"; then
        remove_supervisor_control_files "$supervisor_workspace"
        return 1
    fi
    if ! env GIT_DIR="$ambient_repository/.git" \
        GIT_WORK_TREE="$ambient_repository" \
        XDG_CONFIG_HOME="$install_config_home" \
        make -C "$REPO_ROOT" HOME="$install_home" install; then
        printf 'Supervisor make install failed.\n' >&2
        remove_supervisor_control_files "$supervisor_workspace"
        return 1
    fi
    if ! run_complete_child installed "$installed_runner" \
        "$installed_completion" "$installed_manifest" \
        "$ambient_repository"; then
        remove_supervisor_control_files "$supervisor_workspace"
        return 1
    fi
    printf 'PASS INTEGRATION-SUITE: complete source and installed integration suites\n'

    if ! run_observation_supervisor "$supervisor_workspace" source \
        "$SOURCE_RUNNER" "$ambient_repository"; then
        remove_supervisor_control_files "$supervisor_workspace"
        return 1
    fi
    if ! run_observation_supervisor "$supervisor_workspace" installed \
        "$installed_runner" "$ambient_repository"; then
        remove_supervisor_control_files "$supervisor_workspace"
        return 1
    fi
    if ! run_forced_cleanup_supervisor "$supervisor_workspace" source \
        "$SOURCE_RUNNER" "$ambient_repository"; then
        remove_supervisor_control_files "$supervisor_workspace"
        return 1
    fi
    if ! run_forced_cleanup_supervisor "$supervisor_workspace" installed \
        "$installed_runner" "$ambient_repository"; then
        remove_supervisor_control_files "$supervisor_workspace"
        return 1
    fi
    remove_supervisor_control_files "$supervisor_workspace"
    printf 'PASS SUPERVISOR-CLEANUP: outer supervisor cleanup and failure retention\n'
    printf 'PASS RESOURCE-OBSERVATION: live isolation, cleanup, and failure evidence\n'
}

function main {
    require_dependencies
    WORKSPACE=$(mktemp -d /tmp/tmux-runner-test.XXXXXX)
    record_manifest workspace "$WORKSPACE"
    mkdir -p -- "$WORKSPACE/pty"

    test_t1_static
    test_t2_create
    test_t3_attach
    test_t4_list
    test_t5_completion
    test_t6_install
    test_t7_documentation
    test_t8_help
    test_t9_version
    test_server_command_path
    test_server_isolation
    test_server_config_lifecycle
    test_server_client_boundary
    test_identity_repository
    test_identity_collision
    test_identity_worktree
    test_identity_explicit
    test_identity_regression
    test_catalog_configuration
    test_catalog_discovery
    test_catalog_selection
    test_catalog_failures
    test_catalog_regression
    test_navigation_recent
    test_navigation_previous
    test_navigation_recovery
    test_navigation_concurrency
    test_navigation_regression
    test_installation_bundle
    test_interface_bundle
    exercise_entry_session_identity
    printf 'PASS: %d milestone checks completed (%s)\n' \
        "$TESTS_PASSED" "$TEST_VARIANT"
}

require_test_process_git_boundary
if [[ "${TMUX_RUNNER_TEST_CHILD:-}" == "1" ]]; then
    if [[ "${TMUX_RUNNER_TEST_FORCE_FAILURE:-}" == "1" ]]; then
        run_forced_cleanup_probe
    elif [[ "${TMUX_RUNNER_TEST_OBSERVATION:-}" == "1" ]]; then
        run_observation_probe
    else
        main "$@"
    fi
else
    run_supervisor
fi
