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
readonly README="$REPO_ROOT/README.md"
readonly PTY_TIMEOUT_SECONDS=12
readonly POLL_INTERVAL_SECONDS=0.05

TMUX_PATH=""
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

function cleanup {
    local root=""
    local cleanup_pid=""
    local extra_pid=""
    local extra_fd=""

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
        env -u TMUX TMUX_TMPDIR="$root" tmux kill-server >/dev/null 2>&1
    done
    if [[ -n "$WORKSPACE" ]] && [[ -d "$WORKSPACE" ]] && \
        [[ "$WORKSPACE" == /tmp/tmux-runner-test.* ]]; then
        rm -rf -- "$WORKSPACE"
    fi
}

trap cleanup EXIT
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
        hostname
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
}

function create_tmux_root {
    local label="$1"

    NEW_TMUX_ROOT="$WORKSPACE/$label/tmux-root"
    mkdir -p -- "$NEW_TMUX_ROOT"
    chmod 0700 "$NEW_TMUX_ROOT"
    TMUX_ROOTS+=("$NEW_TMUX_ROOT")
}

function run_tmux {
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
        -F '#{session_name}|#{session_id}|#{window_id}|#{pane_id}|#{pane_current_path}' | \
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
    assert_not_contains "$LAST_TRANSCRIPT" "$TMUX_PATH attach-session" \
        "$label called attach-session"
    assert_not_contains "$LAST_TRANSCRIPT" "$TMUX_PATH switch-client" \
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
    assert_not_contains "$LAST_TRANSCRIPT" "$TMUX_PATH has-session" \
        "$label called has-session"
    assert_not_contains "$LAST_TRANSCRIPT" "$TMUX_PATH new-session" \
        "$label called new-session"
    assert_not_contains "$LAST_TRANSCRIPT" "$TMUX_PATH attach-session" \
        "$label called attach-session"
    assert_not_contains "$LAST_TRANSCRIPT" "$TMUX_PATH switch-client" \
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
    EXTRA_PTY_PIDS+=("$pid_one")
    exec {fd_one}>"$fifo_one"
    EXTRA_PTY_FDS+=("$fd_one")

    setsid env -u TMUX HOME="$home" XDG_CONFIG_HOME="$xdg_home" \
        TMUX_TMPDIR="$root" SHELL=/bin/bash \
        timeout --foreground -k 2s "${PTY_TIMEOUT_SECONDS}s" \
        script -q -e -f -c "$command_two" "$transcript_two" \
        < "$fifo_two" > "$console_two" 2>&1 &
    pid_two=$!
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
        "$TMUX_PATH attach-session -t =$session_name" \
        "$label first runner did not attach exactly"
    assert_contains "$transcript_two" \
        "$TMUX_PATH attach-session -t =$session_name" \
        "$label second runner did not attach exactly"
    assert_contains "$transcript_one" \
        "$TMUX_PATH new-session -d -s $session_name" \
        "$label first runner did not attempt creation"
    assert_contains "$transcript_two" \
        "$TMUX_PATH new-session -d -s $session_name" \
        "$label second runner did not attempt creation"
    if grep -F -- '+ create_rc=1' "$transcript_one" >/dev/null; then
        recovery_trace="$transcript_one"
    elif grep -F -- '+ create_rc=1' "$transcript_two" >/dev/null; then
        recovery_trace="$transcript_two"
    else
        fail_test "$label did not exercise duplicate-create recovery"
    fi
    recheck_count=$(grep -Fc -- \
        "$TMUX_PATH has-session -t =$session_name" "$recovery_trace") || true
    if (( recheck_count < 2 )); then
        fail_test "$label loser did not recheck the exact session"
    fi
}

function start_source_client {
    local label="$1"
    local root="$2"
    local home="$3"
    local xdg_home="$4"
    local source_session="$5"

    start_pty_command "$label-client" "$root" "$home" "$xdg_home" \
        tmux attach-session -t "=$source_session"
    if ! wait_for_client_session "$root" "$source_session"; then
        fail_test "$label client did not attach to $source_session"
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
    assert_not_contains "$LAST_INSIDE_TRACE" "$TMUX_PATH attach-session" \
        "$label called attach-session"
    assert_not_contains "$LAST_INSIDE_TRACE" "$TMUX_PATH switch-client" \
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
    assert_command_succeeds "test Bash syntax failed" bash -n "$TEST_DIR/test-tmux-runner.bash"
    assert_command_succeeds "ShellCheck reported a finding" \
        shellcheck "$RUNNER" "$COMPLETION" "$TEST_DIR/test-tmux-runner.bash"
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
    if ! wait_for_transcript_text "$TMUX_PATH has-session -t =$default_name"; then
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
        "$TMUX_PATH new-session -d -s alias_session_blue" \
        "alias create did not normalize the session name"
    identity_before=$(session_identity "$root" alias_session_blue)
    run_outside_success t2-alias-reuse "$root" "$home" "$xdg_home" \
        "$RUNNER" alias_session_blue create -s alias.session:blue -c "$alias_dir"
    assert_equal "$identity_before" "$(session_identity "$root" alias_session_blue)" \
        "existing session reuse changed its identifiers"
    assert_not_contains "$LAST_TRANSCRIPT" "$TMUX_PATH new-session" \
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
    run_tmux "$root" new-session -d -s source-create
    run_inside_success t2-inside-new "$root" "$home" "$xdg_home" \
        source-create inside_new "$RUNNER" create -s inside.new -c "$inside_dir"
    assert_contains "$LAST_INSIDE_TRACE" \
        "$TMUX_PATH switch-client -t =inside_new" \
        "inside create did not use an exact switch target"

    identity_before=$(session_identity "$root" alias_session_blue)
    run_inside_success t2-inside-reuse "$root" "$home" "$xdg_home" \
        source-create alias_session_blue "$RUNNER" c -s alias.session:blue \
        -c "$alias_dir"
    assert_equal "$identity_before" "$(session_identity "$root" alias_session_blue)" \
        "inside reuse changed existing session identifiers"
    assert_not_contains "$LAST_INSIDE_TRACE" "$TMUX_PATH new-session" \
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
    local standard_trace="$TMUX_PATH attach-session -t =target"
    local switch_trace="$TMUX_PATH switch-client -t =target"

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
        "$TMUX_PATH attach-session -t =dotted_target_blue" \
        "outside attach did not normalize separators"
    run_inside_success t3-dotted-inside "$root" "$home" "$xdg_home" \
        source dotted_target_blue "$RUNNER" a -t dotted.target:blue
    assert_contains "$LAST_INSIDE_TRACE" \
        "$TMUX_PATH switch-client -t =dotted_target_blue" \
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
        "$TMUX_PATH attach-session -t =prefix-only" \
        "missing exact target was not passed to attach-session"
    run_inside_failure t3-prefix-missing-inside "$root" "$home" "$xdg_home" \
        source "$RUNNER" a -t prefix-only
    assert_contains "$LAST_INSIDE_TRACE" \
        "$TMUX_PATH switch-client -t =prefix-only" \
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
        "$TMUX_PATH attach-session -t =alpha" \
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
        "$TMUX_PATH switch-client -t =gamma" \
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
        create c ls attach a -h --help

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
    local inventory=""
    local expected_inventory=""

    create_tmux_root t6
    root="$NEW_TMUX_ROOT"
    home="$WORKSPACE/t6/home with space"
    xdg_home="$WORKSPACE/t6/xdg"
    mkdir -p -- "$home" "$xdg_home"
    installed_runner="$home/.local/bin/tmux-runner"
    installed_completion="$home/.local/share/bash-completion/completions/tmux-runner"

    assert_command_succeeds "make install failed" \
        make -C "$REPO_ROOT" HOME="$home" install
    inventory=$(find "$home" \( -type f -o -type l \) -print | LC_ALL=C sort)
    expected_inventory=$(printf '%s\n%s\n' \
        "$installed_runner" "$installed_completion" | LC_ALL=C sort)
    assert_equal "$expected_inventory" "$inventory" \
        "install wrote an unexpected file"
    assert_equal "0755" "0$(stat -c '%a' "$installed_runner")" \
        "installed runner mode is wrong"
    assert_equal "0644" "0$(stat -c '%a' "$installed_completion")" \
        "installed completion mode is wrong"
    assert_command_succeeds "installed runner differs from shipped runner" \
        cmp -s "$RUNNER" "$installed_runner"
    assert_command_succeeds \
        "installed completion differs from shipped completion" \
        cmp -s "$COMPLETION" "$installed_completion"

    run_tmux "$root" -f /dev/null new-session -d -s install-target
    run_outside_success t6-installed-attach "$root" "$home" "$xdg_home" \
        "$installed_runner" install-target attach -t install-target
    assert_contains "$LAST_TRANSCRIPT" \
        "$TMUX_PATH attach-session -t =install-target" \
        "installed runner did not use the exact target"
    pass_test T6 "isolated local installation and installed execution"
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
    assert_contains "$README" "inherits the current client's" \
        "README omits inside client data flow"
    assert_contains "$README" ".local/bin/tmux-runner" \
        "README omits runner install path"
    assert_contains "$README" \
        ".local/share/bash-completion/completions/tmux-runner" \
        "README omits completion install path"
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
    assert_contains "$README" "bash --version" \
        "README omits the Bash version check"
    assert_contains "$README" "make --version" \
        "README omits the Make version check"
    assert_contains "$README" "export PATH=\"\$HOME/.local/bin:\$PATH\"" \
        "README omits current-shell PATH preparation"
    assert_contains "$README" 'make HOME="/path/to/home" install' \
        "README test-home install command does not quote HOME"
    assert_contains "$README" 'make -n HOME="/path/to/home" install' \
        "README test-home dry-run command does not quote HOME"
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
    assert_contains "$WORKSPACE/t8/create-long.stdout" "-s <session-name>" \
        "create help omitted the session option"
    assert_contains "$WORKSPACE/t8/create-long.stdout" "-c <folder>" \
        "create help omitted the folder option"
    assert_contains "$WORKSPACE/t8/create-long.stdout" \
        "<folder>-<short-hostname>" \
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

function main {
    require_dependencies
    WORKSPACE=$(mktemp -d /tmp/tmux-runner-test.XXXXXX)
    mkdir -p -- "$WORKSPACE/pty"

    test_t1_static
    test_t2_create
    test_t3_attach
    test_t4_list
    test_t5_completion
    test_t6_install
    test_t7_documentation
    test_t8_help
    printf 'PASS: %d milestone checks completed\n' "$TESTS_PASSED"
}

main "$@"
