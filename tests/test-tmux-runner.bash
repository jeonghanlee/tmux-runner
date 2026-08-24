#!/usr/bin/env bash

set -euo pipefail

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
readonly RUNNER="$REPO_ROOT/bin/tmux-runner"
readonly COMPLETION="$REPO_ROOT/bin/tmux-runner-completion.bash"
readonly VERSION_INJECTOR="$REPO_ROOT/configure/inject-runner-version.bash"
readonly README="$REPO_ROOT/README.md"
readonly RUNNER_CONFIG="$REPO_ROOT/config/tmux.conf"
readonly RUNNER_SERVER_NAME="tmux-runner"
readonly PTY_TIMEOUT_SECONDS=12
readonly POLL_INTERVAL_SECONDS=0.05

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
TESTS_PASSED=0
TMUX_ROOTS=()
EXTRA_PTY_PIDS=()
EXTRA_PTY_FDS=()

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
        awk grep sed tr env mkdir chmod rm mkfifo mktemp tee tail sleep
        hostname git sha256sum date cp ln
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

function session_identity {
    local root="$1"
    local session_name="$2"

    run_tmux "$root" list-panes -t "=$session_name" -F \
        '#{session_id}|#{window_id}|#{pane_id}'
}

function pane_directory {
    local root="$1"
    local session_name="$2"

    run_tmux "$root" list-panes -t "=$session_name" -F \
        '#{pane_current_path}'
}

function session_path {
    local root="$1"
    local session_name="$2"

    run_tmux "$root" show-options -qv -t "=$session_name:" \
        @tmux-runner-path
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
        if [[ "$marked_path" == "$expected_path" ]]; then
            printf '%s\n' "$session_name"
        fi
    done < <(session_names "$root")
}

function init_git_repository {
    local repository="$1"

    mkdir -p -- "$repository"
    git -C "$repository" init -q
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
    assert_not_contains "$LAST_TRANSCRIPT" \
        "$TMUX_RUNNER_TRACE_PREFIX attach-session" \
        "$label called attach-session"
    assert_not_contains "$LAST_TRANSCRIPT" \
        "$TMUX_RUNNER_TRACE_PREFIX switch-client" \
        "$label called switch-client"
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
    assert_not_contains "$LAST_TRANSCRIPT" \
        "$TMUX_RUNNER_TRACE_PREFIX attach-session" \
        "$label called attach-session"
    assert_not_contains "$LAST_TRANSCRIPT" \
        "$TMUX_RUNNER_TRACE_PREFIX switch-client" \
        "$label called switch-client"
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
    # Positional parameters are expanded by the child Bash process.
    # shellcheck disable=SC2016
    local wrapper='printf "ready\n" > "$1"; IFS= read -r < "$2"; shift 2; exec "$@"'

    mkfifo -- "$barrier_fifo" "$fifo_one" "$fifo_two"
    exec {barrier_fd}<>"$barrier_fifo"
    EXTRA_PTY_FDS+=("$barrier_fd")
    printf -v command_one '%q ' bash -c "$wrapper" concurrent-create \
        "$ready_one" "$barrier_fifo" bash -x "$runner" create \
        -s "$session_name" -c "$directory"
    command_one="${command_one% }"
    printf -v command_two '%q ' bash -c "$wrapper" concurrent-create \
        "$ready_two" "$barrier_fifo" bash -x "$runner" create \
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
    assert_contains "$transcript_one" \
        "$TMUX_RUNNER_TRACE_PREFIX attach-session -t =$session_name" \
        "$label first runner did not attach exactly"
    assert_contains "$transcript_two" \
        "$TMUX_RUNNER_TRACE_PREFIX attach-session -t =$session_name" \
        "$label second runner did not attach exactly"
    assert_contains "$transcript_one" \
        "$TMUX_RUNNER_TRACE_PREFIX new-session -d -s $session_name" \
        "$label first runner did not attempt creation"
    assert_contains "$transcript_two" \
        "$TMUX_RUNNER_TRACE_PREFIX new-session -d -s $session_name" \
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
    assert_contains "$transcript_one" \
        "$race_trace_prefix attach-session -t =$target_one" \
        "$label first client entered the wrong path"
    assert_contains "$transcript_two" \
        "$race_trace_prefix attach-session -t =$target_two" \
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
    assert_not_contains "$LAST_INSIDE_TRACE" \
        "$TMUX_RUNNER_TRACE_PREFIX attach-session" \
        "$label called attach-session"
    assert_not_contains "$LAST_INSIDE_TRACE" \
        "$TMUX_RUNNER_TRACE_PREFIX switch-client" \
        "$label called switch-client"
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

function test_t1_static {
    assert_command_succeeds "runner Bash syntax failed" bash -n "$RUNNER"
    assert_command_succeeds "completion Bash syntax failed" bash -n "$COMPLETION"
    assert_command_succeeds "version injector Bash syntax failed" \
        bash -n "$VERSION_INJECTOR"
    assert_command_succeeds "test Bash syntax failed" bash -n "$TEST_DIR/test-tmux-runner.bash"
    assert_command_succeeds "ShellCheck reported a finding" \
        shellcheck "$RUNNER" "$COMPLETION" "$VERSION_INJECTOR" \
        "$TEST_DIR/test-tmux-runner.bash"
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
    assert_contains "$LAST_TRANSCRIPT" \
        "$TMUX_RUNNER_TRACE_PREFIX new-session -d -s alias_session_blue" \
        "alias create did not normalize the session name"
    identity_before=$(session_identity "$root" alias_session_blue)
    run_outside_success t2-alias-reuse "$root" "$home" "$xdg_home" \
        "$RUNNER" alias_session_blue create -s alias.session:blue -c "$alias_dir"
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
    assert_contains "$LAST_INSIDE_TRACE" \
        "$TMUX_RUNNER_TRACE_PREFIX switch-client -t =inside_new" \
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
    local standard_trace="$TMUX_RUNNER_TRACE_PREFIX attach-session -t =target"
    local switch_trace="$TMUX_RUNNER_TRACE_PREFIX switch-client -t =target"

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
    assert_contains "$LAST_TRANSCRIPT" "$standard_trace" \
        "attach -t did not use the exact target"
    run_outside_success t3-attach-positional "$root" "$home" "$xdg_home" \
        "$RUNNER" target attach target
    run_outside_success t3-a-t "$root" "$home" "$xdg_home" \
        "$RUNNER" target a -t target
    run_outside_success t3-a-positional "$root" "$home" "$xdg_home" \
        "$RUNNER" target a target
    run_outside_success t3-attach-terminator "$root" "$home" "$xdg_home" \
        "$RUNNER" target attach -- target
    run_outside_success t3-a-terminator "$root" "$home" "$xdg_home" \
        "$RUNNER" target a -- target

    run_inside_success t3-inside-attach-t "$root" "$home" "$xdg_home" \
        source target "$RUNNER" attach -t target
    assert_contains "$LAST_INSIDE_TRACE" "$switch_trace" \
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
    assert_contains "$LAST_TRANSCRIPT" \
        "$TMUX_RUNNER_TRACE_PREFIX attach-session -t =dotted_target_blue" \
        "outside attach did not normalize separators"
    run_inside_success t3-dotted-inside "$root" "$home" "$xdg_home" \
        source dotted_target_blue "$RUNNER" a -t dotted.target:blue
    assert_contains "$LAST_INSIDE_TRACE" \
        "$TMUX_RUNNER_TRACE_PREFIX switch-client -t =dotted_target_blue" \
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
        "$TMUX_RUNNER_TRACE_PREFIX attach-session -t =prefix-only" \
        "missing exact target was not passed to attach-session"
    run_inside_failure t3-prefix-missing-inside "$root" "$home" "$xdg_home" \
        source "$RUNNER" a -t prefix-only
    assert_contains "$LAST_INSIDE_TRACE" \
        "$TMUX_RUNNER_TRACE_PREFIX switch-client -t =prefix-only" \
        "missing exact target was not passed to switch-client"

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
    assert_contains "$LAST_TRANSCRIPT" \
        "$TMUX_RUNNER_TRACE_PREFIX attach-session -t =alpha" \
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
    assert_contains "$LAST_INSIDE_TRACE" \
        "$TMUX_RUNNER_TRACE_PREFIX switch-client -t =gamma" \
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
        create c ls attach a -V --version -h --help

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
    COMP_WORDS=(tmux-runner attach -)
    COMP_CWORD=2
    _tmux_runner
    assert_reply_set "attach option completion set is wrong" -t -h --help
    COMP_WORDS=(tmux-runner a -)
    COMP_CWORD=2
    _tmux_runner
    assert_reply_set "a option completion set is wrong" -t -h --help

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
        "$RUNNER" > "$source_normalized"
    sed -e 's/^readonly RUNNER_GIT_HASH=.*/readonly RUNNER_GIT_HASH="normalized"/' \
        -e 's/^readonly RUNNER_COMMIT_DATE=.*/readonly RUNNER_COMMIT_DATE="normalized"/' \
        -e 's/^readonly RUNNER_INSTALL_DATE=.*/readonly RUNNER_INSTALL_DATE="normalized"/' \
        "$installed_runner" > "$installed_normalized"
    assert_command_succeeds \
        "installed runner differs outside injected metadata" \
        cmp -s "$source_normalized" "$installed_normalized"
    assert_command_succeeds \
        "installed completion differs from shipped completion" \
        cmp -s "$COMPLETION" "$installed_completion"
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
    assert_contains "$LAST_TRANSCRIPT" \
        "$TMUX_PATH -L $RUNNER_SERVER_NAME -f '$installed_config' attach-session -t =install-target" \
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
    assert_contains "$README" "Inside the dedicated server" \
        "README omits inside client data flow"
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
    run_help_case list-short "Usage: tmux-runner ls" ls -h
    run_help_case list-long "Usage: tmux-runner ls" ls --help
    run_help_case attach-short "Usage: tmux-runner attach" attach -h
    run_help_case attach-long "Usage: tmux-runner attach" attach --help
    run_help_case a-short "Usage: tmux-runner a" a -h
    run_help_case a-long "Usage: tmux-runner a" a --help

    assert_contains "$WORKSPACE/t8/top-long.stdout" "create, c" \
        "top-level help omitted the create command summary"
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
    local rc=0

    mkdir -p -- "$WORKSPACE/t9/unrelated" "$fixture_seed/bin" \
        "${clean_installed%/*}" "${dirty_installed%/*}" \
        "${locked_installed%/*}" "${missing_anchor%/*}" \
        "${duplicate_anchor%/*}"
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
    assert_equal "$short_output" "$long_output" \
        "short and long version forms differ"
    assert_equal "tmux-runner version 0.1.0 (${expected_hash} (live))" \
        "${long_output%%$'\n'*}" \
        "source runner reported the wrong live version or Git hash"
    assert_equal "$expected_commit_date" \
        "$(printf '%s\n' "$long_output" | sed -n 's/^commit date:  //p')" \
        "source runner reported the wrong live commit date"
    assert_equal "live" \
        "$(printf '%s\n' "$long_output" | sed -n 's/^install date: //p')" \
        "source runner did not identify its live install state"

    # Commit once, then copy without running Git in the copies. The relocated
    # files have new inodes while the copied index retains its cached stat
    # data, which distinguishes a content diff from an index-only verdict.
    cp "$RUNNER" "$seed_runner"
    git -C "$fixture_seed" init -q
    git -C "$fixture_seed" add bin/tmux-runner
    git -C "$fixture_seed" -c core.hooksPath=/dev/null \
        -c user.name=tmux-runner-test \
        -c user.email=tmux-runner-test@example.invalid \
        commit -qm "Create version fixture"
    fixture_hash=$(git -C "$fixture_seed" rev-parse --short HEAD)
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

    no_git_output=$(env PATH=/nonexistent /bin/bash "$RUNNER" --version)
    assert_equal "tmux-runner version 0.1.0 (unknown)" \
        "${no_git_output%%$'\n'*}" \
        "dependency-free version output is wrong"
    assert_equal "unreleased" \
        "$(printf '%s\n' "$no_git_output" | sed -n 's/^commit date:  //p')" \
        "dependency-free version commit date is wrong"
    assert_equal "unreleased" \
        "$(printf '%s\n' "$no_git_output" | sed -n 's/^install date: //p')" \
        "dependency-free install date is wrong"

    sed '/^readonly RUNNER_GIT_HASH=/d' "$RUNNER" > "$missing_anchor"
    rc=0
    bash "$VERSION_INJECTOR" "$missing_anchor" "$clean_repository" \
        > "$stdout_file" 2> "$stderr_file" || rc=$?
    assert_equal "2" "$rc" \
        "injector accepted a missing metadata declaration"
    assert_contains "$stderr_file" \
        "expected exactly one readonly RUNNER_GIT_HASH declaration" \
        "missing metadata declaration error is unclear"

    cp "$RUNNER" "$duplicate_anchor"
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
    pass_test T9 "source and installed version metadata"
}

function test_m3_t1_static_server_path {
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
    pass_test M3-T1 "centralized dedicated-server path"
}

function test_m3_t2_server_isolation {
    local root=""
    local home=""
    local xdg_home=""
    local list_output="$WORKSPACE/m3-t2/list.out"
    local list_error="$WORKSPACE/m3-t2/list.err"
    local completion_output=""
    local default_before=""
    local rc=0

    create_tmux_root m3-t2
    root="$NEW_TMUX_ROOT"
    home="$WORKSPACE/m3-t2/home"
    xdg_home="$WORKSPACE/m3-t2/xdg"
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

    run_outside_success m3-t2-attach "$root" "$home" "$xdg_home" \
        "$RUNNER" runner-only attach runner-only
    run_outside_success m3-t2-create "$root" "$home" "$xdg_home" \
        "$RUNNER" runner-created create -s runner-created -c "$home"
    assert_equal "$default_before" "$(one_server_snapshot "$root" default)" \
        "runner operations changed the default server"
    assert_session_set "$root" "dedicated session set is wrong" \
        runner-only runner-created
    assert_equal "default-only" \
        "$(run_default_tmux "$root" list-sessions -F '#{session_name}')" \
        "default server session set changed"
    pass_test M3-T2 "create, list, attach, and completion server isolation"
}

function test_m3_t3_config_lifecycle {
    local root=""
    local home=""
    local xdg_home=""
    local config_file=""
    local default_before=""
    local marker=""
    local binding=""

    create_tmux_root m3-t3
    root="$NEW_TMUX_ROOT"
    home="$WORKSPACE/m3-t3/home"
    xdg_home="$WORKSPACE/m3-t3/xdg"
    config_file="$xdg_home/tmux-runner/tmux.conf"
    mkdir -p -- "$home" "${config_file%/*}"
    printf '%s\n' 'set -g @general-marker general' > "$home/.tmux.conf"
    env -u TMUX HOME="$home" TMUX_TMPDIR="$root" \
        tmux -f "$home/.tmux.conf" new-session -d -s default-config
    assert_equal "general" \
        "$(run_default_tmux "$root" show-options -gv @general-marker)" \
        "default server did not load its general marker"
    default_before=$(one_server_snapshot "$root" default)

    run_outside_success m3-t3-absent "$root" "$home" "$xdg_home" \
        "$RUNNER" isolated create -s isolated -c "$home"
    marker=$(run_tmux "$root" show-options -gv @general-marker 2>/dev/null || true)
    assert_equal "" "$marker" \
        "absent runner config allowed the general tmux config"
    run_tmux "$root" kill-server

    cp "$RUNNER_CONFIG" "$config_file"
    run_outside_success m3-t3-starter "$root" "$home" "$xdg_home" \
        "$RUNNER" starter create -s starter -c "$home"
    run_tmux "$root" kill-server

    {
        printf '%s\n' 'set -g @runner-marker one'
        printf '%s\n' 'set -g status off'
        printf '%s\n' 'bind-key C-r display-message runner-one'
    } > "$config_file"
    run_outside_success m3-t3-first "$root" "$home" "$xdg_home" \
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
    run_outside_success m3-t3-running "$root" "$home" "$xdg_home" \
        "$RUNNER" configured attach configured
    assert_equal "one" "$(run_tmux "$root" show-options -gv @runner-marker)" \
        "running server reloaded its config"
    assert_equal "off" "$(run_tmux "$root" show-options -gv status)" \
        "running server changed its status option"

    run_tmux "$root" kill-server
    run_outside_success m3-t3-restart "$root" "$home" "$xdg_home" \
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
    pass_test M3-T3 "isolated first-start config and dedicated-only reload"
}

function test_m3_t4_client_boundary {
    local root=""
    local home=""
    local xdg_home=""
    local source_session="default-client"
    local status=""
    local runner_socket=""

    create_tmux_root m3-t4
    root="$NEW_TMUX_ROOT"
    home="$WORKSPACE/m3-t4/home"
    xdg_home="$WORKSPACE/m3-t4/xdg"
    mkdir -p -- "$home" "$xdg_home"
    runner_socket="$root/tmux-$UID/$RUNNER_SERVER_NAME"
    run_default_tmux "$root" -f /dev/null new-session -d -s "$source_session"
    start_default_source_client m3-t4 "$root" "$home" "$xdg_home" \
        "$source_session"
    if [[ -e "$runner_socket" ]]; then
        fail_test "client-boundary fixture started the dedicated socket early"
    fi

    start_dual_state_monitor m3-t4 "$root"
    invoke_runner_inside_default m3-t4-reject "$root" "$home" "$xdg_home" \
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
    stop_state_monitor m3-t4
    if [[ -e "$runner_socket" ]]; then
        fail_test "other-server rejection created the dedicated socket"
    fi

    invoke_runner_inside_default m3-t4-help "$root" "$home" "$xdg_home" \
        "$source_session" "$RUNNER" --help
    if ! wait_for_file "$LAST_INSIDE_STATUS"; then
        fail_test "help inside another server did not record status"
    fi
    assert_equal "0" "$(inside_runner_status)" \
        "help inside another server failed"
    assert_contains "$LAST_INSIDE_TRACE" "Session commands use the dedicated" \
        "help omitted the dedicated-server contract"

    invoke_runner_inside_default m3-t4-version "$root" "$home" "$xdg_home" \
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
    pass_test M3-T4 "dedicated switching and cold other-server rejection"
}

function test_m4_t1_repository_identity {
    local root=""
    local home="$WORKSPACE/m4-t1/home"
    local xdg_home="$WORKSPACE/m4-t1/xdg"
    local repository="$WORKSPACE/m4-t1/project.repo"
    local subdir_one="$repository/src/one"
    local subdir_two="$repository/src/two"
    local short_hostname=""
    local session_name=""
    local identity_before=""

    create_tmux_root m4-t1
    root="$NEW_TMUX_ROOT"
    mkdir -p -- "$home" "$xdg_home"
    init_git_repository "$repository"
    mkdir -p -- "$subdir_one" "$subdir_two"
    short_hostname=$(hostname -s)
    short_hostname="${short_hostname//./_}"
    short_hostname="${short_hostname//:/_}"
    session_name="project_repo-$short_hostname"

    run_outside_success m4-t1-first "$root" "$home" "$xdg_home" \
        "$RUNNER" "$session_name" create -c "$subdir_one"
    assert_equal "$repository" "$(session_path "$root" "$session_name")" \
        "repository session recorded the wrong canonical path"
    assert_equal "$repository" "$(pane_directory "$root" "$session_name")" \
        "repository session did not start at the Git top level"
    identity_before=$(session_identity "$root" "$session_name")

    run_outside_success m4-t1-second "$root" "$home" "$xdg_home" \
        "$RUNNER" "$session_name" create -c "$subdir_two"
    assert_equal "$identity_before" \
        "$(session_identity "$root" "$session_name")" \
        "two repository subdirectories did not reuse one session"
    assert_not_contains "$LAST_TRANSCRIPT" \
        "$TMUX_RUNNER_TRACE_PREFIX new-session" \
        "repository path reuse created another session"
    pass_test M4-T1 "Git top-level path identity and subdirectory reuse"
}

function test_m4_t2_collision_identity {
    local root=""
    local home="$WORKSPACE/m4-t2/home"
    local xdg_home="$WORKSPACE/m4-t2/xdg"
    local short_hostname=""
    local repo_one="$WORKSPACE/m4-t2/base-one/shared"
    local repo_two="$WORKSPACE/m4-t2/base-two/shared"
    local deep_one="$WORKSPACE/m4-t2/top-one/common/deep"
    local deep_two="$WORKSPACE/m4-t2/top-two/common/deep"
    local triple_one="$WORKSPACE/m4-t2/head-one/same/middle/triple"
    local triple_two="$WORKSPACE/m4-t2/head-two/same/middle/triple"
    local norm_one="$WORKSPACE/m4-t2/hash/alpha.dot/norm"
    local norm_two="$WORKSPACE/m4-t2/hash/alpha:dot/norm"
    local race_one="$WORKSPACE/m4-t2/race-one/race"
    local race_two="$WORKSPACE/m4-t2/race-two/race"
    local hash_output=""
    local path_hash=""
    local full_stem=""
    local occupied_name=""
    local hash_name=""
    local unrelated_path="$WORKSPACE/m4-t2/unrelated"

    create_tmux_root m4-t2
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

    run_outside_success m4-t2-base-one "$root" "$home" "$xdg_home" \
        "$RUNNER" "shared-$short_hostname" create -c "$repo_one"
    run_outside_success m4-t2-base-two "$root" "$home" "$xdg_home" \
        "$RUNNER" "base-two-shared-$short_hostname" create -c "$repo_two"
    assert_equal "$repo_one" \
        "$(session_path "$root" "shared-$short_hostname")" \
        "first same-basename repository path changed"
    assert_equal "$repo_two" \
        "$(session_path "$root" "base-two-shared-$short_hostname")" \
        "one-parent collision name recorded the wrong path"

    run_outside_success m4-t2-deep-one "$root" "$home" "$xdg_home" \
        "$RUNNER" "deep-$short_hostname" create -c "$deep_one"
    run_outside_success m4-t2-deep-two "$root" "$home" "$xdg_home" \
        "$RUNNER" "top-two-common-deep-$short_hostname" create -c "$deep_two"
    run_outside_success m4-t2-triple-one "$root" "$home" "$xdg_home" \
        "$RUNNER" "triple-$short_hostname" create -c "$triple_one"
    run_outside_success m4-t2-triple-two "$root" "$home" "$xdg_home" \
        "$RUNNER" "head-two-same-middle-triple-$short_hostname" create \
        -c "$triple_two"

    run_outside_success m4-t2-norm-one "$root" "$home" "$xdg_home" \
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
    run_outside_success m4-t2-norm-two "$root" "$home" "$xdg_home" \
        "$RUNNER" "$hash_name" create -c "$norm_two"
    assert_equal "$norm_two" "$(session_path "$root" "$hash_name")" \
        "normalized collision did not extend the occupied hash prefix"
    assert_equal "$unrelated_path" \
        "$(session_path "$root" "$occupied_name")" \
        "hash collision handling changed the occupied session marker"

    run_concurrent_auto_create m4-t2-race "$root" "$home" "$xdg_home" \
        "$RUNNER" "$race_one" "$race_two"
    assert_equal "1" \
        "$(session_name_for_path "$root" "$race_one" | grep -c .)" \
        "concurrent first path did not keep one session"
    assert_equal "1" \
        "$(session_name_for_path "$root" "$race_two" | grep -c .)" \
        "concurrent second path did not keep one session"
    pass_test M4-T2 "minimum-parent, hash-extension, and concurrent identity"
}

function test_m4_t3_worktree_identity {
    local root=""
    local home="$WORKSPACE/m4-t3/home"
    local xdg_home="$WORKSPACE/m4-t3/xdg"
    local main_repo="$WORKSPACE/m4-t3/main-repo"
    local linked_repo="$WORKSPACE/m4-t3/linked-repo"
    local short_hostname=""
    local main_name=""
    local linked_name=""

    create_tmux_root m4-t3
    root="$NEW_TMUX_ROOT"
    mkdir -p -- "$home" "$xdg_home"
    init_git_repository "$main_repo"
    git -C "$main_repo" worktree add -q -b linked-fixture "$linked_repo"
    short_hostname=$(hostname -s)
    short_hostname="${short_hostname//./_}"
    short_hostname="${short_hostname//:/_}"
    main_name="main-repo-$short_hostname"
    linked_name="linked-repo-$short_hostname"

    run_outside_success m4-t3-main "$root" "$home" "$xdg_home" \
        "$RUNNER" "$main_name" create -c "$main_repo"
    run_outside_success m4-t3-linked "$root" "$home" "$xdg_home" \
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
    pass_test M4-T3 "real linked-worktree identity"
}

function test_m4_t4_directory_and_explicit_identity {
    local root=""
    local home="$WORKSPACE/m4-t4/home"
    local xdg_home="$WORKSPACE/m4-t4/xdg"
    local physical_dir="$WORKSPACE/m4-t4/physical-folder"
    local alias_dir="$WORKSPACE/m4-t4/folder-alias"
    local repository="$WORKSPACE/m4-t4/explicit-repo"
    local single_repo="$WORKSPACE/m4-t4/single-repo"
    local other_path="$WORKSPACE/m4-t4/other-path"
    local short_hostname=""
    local physical_name=""
    local identity_before=""
    local fingerprint_before=""

    create_tmux_root m4-t4
    root="$NEW_TMUX_ROOT"
    mkdir -p -- "$home" "$xdg_home" "$physical_dir" "$other_path"
    ln -s -- "$physical_dir" "$alias_dir"
    init_git_repository "$repository"
    init_git_repository "$single_repo"
    short_hostname=$(hostname -s)
    short_hostname="${short_hostname//./_}"
    short_hostname="${short_hostname//:/_}"
    physical_name="physical-folder-$short_hostname"

    run_outside_success m4-t4-physical "$root" "$home" "$xdg_home" \
        "$RUNNER" "$physical_name" create -c "$physical_dir"
    identity_before=$(session_identity "$root" "$physical_name")
    run_outside_success m4-t4-alias "$root" "$home" "$xdg_home" \
        "$RUNNER" "$physical_name" create -c "$alias_dir"
    assert_equal "$identity_before" \
        "$(session_identity "$root" "$physical_name")" \
        "symlink path did not reuse the physical directory identity"

    run_outside_success m4-t4-explicit-one "$root" "$home" "$xdg_home" \
        "$RUNNER" explicit-one create -s explicit-one -c "$repository"
    run_outside_success m4-t4-explicit-two "$root" "$home" "$xdg_home" \
        "$RUNNER" explicit-two create -s explicit-two -c "$repository"
    fingerprint_before=$(server_fingerprint "$root")
    run_outside_failure m4-t4-ambiguous "$root" "$home" "$xdg_home" \
        "$RUNNER" create -c "$repository"
    assert_contains "$LAST_TRANSCRIPT" "multiple sessions match path" \
        "ambiguous automatic lookup omitted its error"
    assert_contains "$LAST_TRANSCRIPT" "  explicit-one" \
        "ambiguous automatic lookup omitted explicit-one"
    assert_contains "$LAST_TRANSCRIPT" "  explicit-two" \
        "ambiguous automatic lookup omitted explicit-two"
    assert_equal "$fingerprint_before" "$(server_fingerprint "$root")" \
        "ambiguous automatic lookup changed tmux state"

    run_outside_success m4-t4-single-explicit "$root" "$home" "$xdg_home" \
        "$RUNNER" chosen-name create -s chosen-name -c "$single_repo"
    run_outside_success m4-t4-single-auto "$root" "$home" "$xdg_home" \
        "$RUNNER" chosen-name create -c "$single_repo"
    assert_not_contains "$LAST_TRANSCRIPT" \
        "$TMUX_RUNNER_TRACE_PREFIX new-session" \
        "automatic lookup ignored one exact path match"

    run_tmux "$root" new-session -d -s unmarked-name -c "$other_path"
    run_outside_failure m4-t4-unmarked "$root" "$home" "$xdg_home" \
        "$RUNNER" create -s unmarked-name -c "$repository"
    assert_contains "$LAST_TRANSCRIPT" \
        "exists without @tmux-runner-path" \
        "unmarked explicit conflict omitted its guidance"

    run_tmux "$root" new-session -d -s mismatched-name -c "$other_path"
    run_tmux "$root" set-option -t '=mismatched-name:' \
        @tmux-runner-path "$other_path"
    run_outside_failure m4-t4-mismatch "$root" "$home" "$xdg_home" \
        "$RUNNER" create -s mismatched-name -c "$repository"
    assert_contains "$LAST_TRANSCRIPT" "belongs to $other_path" \
        "mismatched explicit conflict omitted the recorded path"
    assert_equal "$other_path" \
        "$(session_path "$root" mismatched-name)" \
        "mismatched explicit conflict changed the recorded path"
    pass_test M4-T4 "physical paths, path-first reuse, and explicit conflicts"
}

function test_m4_t5_regression_integration {
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
    pass_test M4-T5 "M1-M4 command, install, server, and identity integration"
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

function remove_supervisor_control_files {
    local success_manifest="$1"
    local failure_manifest="$2"
    local failure_output="$3"

    rm -f -- "$success_manifest" "$failure_manifest" "$failure_output"
}

function run_forced_cleanup_probe {
    local root=""
    local probe_pid=""

    require_dependencies
    WORKSPACE=$(mktemp -d /tmp/tmux-runner-test.XXXXXX)
    record_manifest workspace "$WORKSPACE"
    mkdir -p -- "$WORKSPACE/pty"
    create_tmux_root cleanup-probe
    root="$NEW_TMUX_ROOT"
    run_tmux "$root" -f /dev/null new-session -d -s cleanup-probe
    setsid sleep 60 &
    probe_pid=$!
    EXTRA_PTY_PIDS+=("$probe_pid")
    record_manifest pid "$probe_pid"
    fail_test "forced cleanup probe"
}

function run_supervisor {
    local script_path="$TEST_DIR/test-tmux-runner.bash"
    local success_manifest=""
    local failure_manifest=""
    local failure_output=""
    local success_workspace=""
    local failure_workspace=""
    local socket_file=""
    local child_rc=0
    local probe_rc=0

    success_manifest=$(mktemp /tmp/tmux-runner-manifest.XXXXXX)
    failure_manifest=$(mktemp /tmp/tmux-runner-manifest.XXXXXX)
    failure_output=$(mktemp /tmp/tmux-runner-failure.XXXXXX)

    TMUX_RUNNER_TEST_CHILD=1 \
        TMUX_RUNNER_TEST_MANIFEST="$success_manifest" \
        bash "$script_path" || child_rc=$?
    success_workspace=$(manifest_workspace "$success_manifest")
    if (( child_rc != 0 )); then
        printf 'Test child failed with exit %d.\n' "$child_rc" >&2
        remove_supervisor_control_files \
            "$success_manifest" "$failure_manifest" "$failure_output"
        return "$child_rc"
    fi
    if [[ -z "$success_workspace" ]] || [[ -e "$success_workspace" ]]; then
        printf 'Passing child left its workspace: %s\n' \
            "$success_workspace" >&2
        remove_supervisor_control_files \
            "$success_manifest" "$failure_manifest" "$failure_output"
        return 1
    fi
    if ! assert_manifest_processes_stopped "$success_manifest"; then
        remove_supervisor_control_files \
            "$success_manifest" "$failure_manifest" "$failure_output"
        return 1
    fi

    TMUX_RUNNER_TEST_CHILD=1 TMUX_RUNNER_TEST_FORCE_FAILURE=1 \
        TMUX_RUNNER_TEST_MANIFEST="$failure_manifest" \
        bash "$script_path" > "$failure_output" 2>&1 || probe_rc=$?
    if (( probe_rc == 0 )); then
        printf 'Forced cleanup probe unexpectedly succeeded.\n' >&2
        remove_supervisor_control_files \
            "$success_manifest" "$failure_manifest" "$failure_output"
        return 1
    fi
    failure_workspace=$(manifest_workspace "$failure_manifest")
    if [[ -z "$failure_workspace" ]] || [[ ! -d "$failure_workspace" ]]; then
        printf 'Forced failure did not preserve its workspace.\n' >&2
        remove_supervisor_control_files \
            "$success_manifest" "$failure_manifest" "$failure_output"
        return 1
    fi
    if ! grep -F -- "Diagnostic workspace: $failure_workspace" \
        "$failure_output" >/dev/null; then
        printf 'Forced failure did not report its workspace.\n' >&2
        remove_supervisor_control_files \
            "$success_manifest" "$failure_manifest" "$failure_output"
        return 1
    fi
    if ! assert_manifest_processes_stopped "$failure_manifest"; then
        remove_supervisor_control_files \
            "$success_manifest" "$failure_manifest" "$failure_output"
        return 1
    fi
    socket_file=$(find "$failure_workspace" -type s -print -quit)
    if [[ -n "$socket_file" ]]; then
        printf 'Forced failure left a socket: %s\n' "$socket_file" >&2
        remove_supervisor_control_files \
            "$success_manifest" "$failure_manifest" "$failure_output"
        return 1
    fi

    chmod -R u+w -- "$failure_workspace"
    rm -rf -- "$failure_workspace"
    remove_supervisor_control_files \
        "$success_manifest" "$failure_manifest" "$failure_output"
    printf 'PASS M3-T5: outer supervisor cleanup and failure retention\n'
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
    test_m3_t1_static_server_path
    test_m3_t2_server_isolation
    test_m3_t3_config_lifecycle
    test_m3_t4_client_boundary
    test_m4_t1_repository_identity
    test_m4_t2_collision_identity
    test_m4_t3_worktree_identity
    test_m4_t4_directory_and_explicit_identity
    test_m4_t5_regression_integration
    printf 'PASS: %d milestone checks completed\n' "$TESTS_PASSED"
}

if [[ "${TMUX_RUNNER_TEST_CHILD:-}" == "1" ]]; then
    if [[ "${TMUX_RUNNER_TEST_FORCE_FAILURE:-}" == "1" ]]; then
        run_forced_cleanup_probe
    else
        main "$@"
    fi
else
    run_supervisor
fi
