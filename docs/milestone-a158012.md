# Work Register

## Scope

This document tracks delivery of the initial local-only `tmux-runner` CLI, its Bash completion, installation, and verification.

**Out of scope:** System-wide installation, service supervision, release execution, GitHub projection, and tmux window or layout management.

Release line: master
Milestone index: a158012
Canonical path: `docs/milestone-a158012.md`
Canonical branch or ref: master
Git upstream: origin/master
Remote tracker: none

Next session entry point: no open milestone or backlog item; create a new canonical plan before further implementation.

## Milestone

### Work

| Group | ID | Work unit | Type | Status | Ready | Deps | Done when / Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Core | M1 | Deliver the local tmux runner | Milestone | Complete | No | D1, D2, D3, D4, D5, D6, D7, D8, D9 | Complete 2026-08-19, commit `fa1658e`; T1-T7 passed through the shipped Bash files, real tmux 3.5a, selected UDS roots, `script(1)` PTYs, and FIFOs; [detail](#m1---deliver-the-local-tmux-runner) |

Milestone tally: Complete 1.

### Decisions

| ID | Decision | Decision Date |
| --- | --- | --- |
| D1 | Derive the default session name as `<folder>-<short-hostname>` from the effective starting directory. | 2026-08-19 |
| D2 | Provide `create` and `c`; accept `-s <session-name>` and `-c <folder>`, defaulting to the derived name and current directory. | 2026-08-19 |
| D3 | Attach immediately after creation and attach to an existing session when the target name already exists. | 2026-08-19 |
| D4 | Provide `attach` and `a`; accept both `-t <session-name>` and a positional session name. | 2026-08-19 |
| D5 | Make `ls` prefix each complete `tmux ls` row with a selection number and attach to the selected session. | 2026-08-19 |
| D6 | Install only under the user account and provide Bash completion for commands, options, folders, and session names. | 2026-08-19 |
| D7 | Require `attach` and `a` to report an error and show valid `-t` and positional command forms when no session target is provided. | 2026-08-19 |
| D8 | Use the tmux CLI as the only session interface: normal runs inherit tmux's selected UDS, test setup clears any inherited `TMUX` and selects an isolated UDS with `TMUX_TMPDIR`, the cold-start test uses empty `HOME` and `XDG_CONFIG_HOME`, prestarted test servers use a first `tmux -f /dev/null` command, inside-client tests use the new client's `TMUX`, and the runner never enumerates socket files directly. | 2026-08-19 |
| D9 | Normalize every CLI-supplied or derived session name by replacing `.` and `:` with `_`, and pass every internal tmux target-session argument as `=<normalized-name>` so lookup and connection require an exact session name. | 2026-08-19 |

### Milestone Details

#### M1 - Deliver the local tmux runner

Origin: a158012 / M1
Identity History: none
GitHub Issue: none
Status: Complete

##### Summary

Deliver one small Bash CLI that creates and enters repository-oriented tmux sessions. The effective starting directory supplies the default session name and tmux working directory. The runner normalizes tmux target separators in session names and requires exact session targets. Every session operation uses the tmux CLI to reach the server through tmux's selected UDS; session discovery, selection, and direct attachment share that interface.

##### Scope

- Add `bin/tmux-runner` with `create`, `c`, `ls`, `attach`, and `a` commands.
- Parse tmux-compatible `-s`, `-c`, and `-t` options and reject ambiguous or extra arguments.
- Use `<folder>-<short-hostname>` when `-s` is absent and the current directory when `-c` is absent.
- Normalize CLI-supplied and derived session names by replacing `.` and `:` with `_`.
- Require exact tmux targets for session lookup, reuse, attachment, and switching.
- Attach to an existing exact-name session instead of creating a duplicate.
- Use `switch-client` inside tmux and `attach-session` outside tmux.
- Run session discovery and lifecycle commands through the tmux CLI against tmux's selected UDS without enumerating or parsing socket files.
- Make `attach` and `a` exit with an error and show both valid command forms when no target is provided.
- Make `ls` prefix each complete `tmux ls` row with a selection number before attaching to the selected session.
- Add `bin/tmux-runner-completion.bash` for command, option, folder, and live session completion.
- Add a `Makefile` that installs to `~/.local/bin/tmux-runner` and `~/.local/share/bash-completion/completions/tmux-runner` without changing shell startup files.
- Add `tests/test-tmux-runner.bash` and a concise `README.md` describing architecture, commands, installation, and data flow.

Out of scope: System paths, root access, systemd, configuration files, daemon management, `stop`, `kill`, `rename`, cross-shell completion, tmux window management, and tmux layout management.

##### Completion Criteria

- `create` and `c` normalize `.` and `:` in the session name, create the expected session in the expected directory, and immediately connect or switch the client.
- An existing exact-name target session is reused without creating a duplicate, and a prefix-only match is not reused.
- `attach` and `a` accept `-t` and positional targets and connect or switch to the exact expected session; without a target, they exit nonzero and show both valid forms.
- `ls` queries the server selected through tmux's UDS context, keeps each complete `tmux ls` row visible, prefixes it with a selection number, validates the selection, and connects or switches to the exact selected session.
- Bash completion returns the defined commands, compatible options, folders, and live session names from tmux's selected UDS.
- `make install` writes exact copies of the two shipped artifacts only, with mode `0755` for the runner and `0644` for the completion.
- The README describes only the shipped architecture, functional behavior, installation, and data flow.
- M1 / T1 through M1 / T7 record passing results from the real shipped files and real tmux process path.

##### Dependencies And Decisions

- D1, D2, D3, D4, D5, D6, D7, D8, and D9.

##### Implementation Plan

Plan Status: accepted
Plan Acceptance: 2026-08-19
Implementation Authorization: 2026-08-19 - full M1 implementation authorized
Superseded Plan Artifacts: none

1. Create `bin/tmux-runner` with command validation, option parsing, directory resolution, session-name derivation, `.` and `:` normalization, exact target construction, and a shared tmux CLI path that inherits tmux's selected UDS context.
2. Implement `create` and `c`, including existing-session reuse, default attachment, and tmux-client switching.
3. Implement attach target validation, usage guidance, full-row interactive list selection, and shared attachment logic.
4. Create `bin/tmux-runner-completion.bash` with context-sensitive command, option, directory, and session completion.
5. Create the local-only `Makefile`; make its `install` target resolve both destinations from `$(HOME)/.local`, accept a command-line `HOME` override for isolated verification, install the runner with mode `0755`, install the completion with mode `0644`, and leave shell startup files unchanged.
6. Create `tests/test-tmux-runner.bash`; clear inherited `TMUX`, select each isolated UDS with `TMUX_TMPDIR`, use empty `HOME` and `XDG_CONFIG_HOME` for the shipped `create` cold start, start precreated servers with a first `tmux -f /dev/null` command, retain the isolated client's `TMUX` for inside-client checks, and exercise the shipped CLI through a real tmux server, a `script(1)` PTY fed by a FIFO, `script -e` child-status propagation, readiness polling, bounded timeouts, and cleanup traps; capture Bash execution traces when the selected tmux subcommand must be verified.
7. Replace the placeholder README with the shipped architecture, functional behavior, session-name normalization and exact-target rules, installation, and data flow, then inspect it against the shipped files.

##### Test Plan

| Label | Layer | Method | Environment | Expected Result |
| --- | --- | --- | --- | --- |
| T1 | Static | Run `bash -n` and ShellCheck on the shipped runner, completion, and test scripts. | Repository checkout | All files pass with exit code 0 and no findings. |
| T2 | CLI integration | Clear inherited `TMUX`; create empty temporary `HOME`, `XDG_CONFIG_HOME`, and `TMUX_TMPDIR` roots plus directories named `default.repo`, `alias-folder`, `named-current-folder`, `folder-only`, and `inside-folder`; confirm that no server socket exists; and invoke the shipped `create` command with defaults from `default.repo` as the first tmux operation. After detaching, run `c -s alias.session:blue -c <alias-folder>` to create a new session, rerun it as `create -s alias.session:blue -c <alias-folder>` to exercise normalized existing-session reuse, run `create -s named-session` from `named-current-folder`, and run `create -c <folder-only>`. Precreate `prefix-target-long`, then run `create -s prefix-target -c <named-current-folder>` and require a distinct exact-name session. Create `source-create`; from a fresh client on it, retain that client's `TMUX`, run `create -s inside.new -c <inside-folder>`, and poll until the client switches to `inside_new`. From another fresh client on `source-create`, run `c -s alias.session:blue -c <alias-folder>` and poll until the client switches to the existing `alias_session_blue` without changing its session or pane identifiers. Then invoke `create extra`, `create -s alias.session:blue -s named-session`, and `create -c <alias-folder> -c <folder-only>` as separate invalid cases. Drive every shipped-runner invocation through a separate `script(1)` PTY and FIFO with `-e`; for a valid outside invocation, poll until the client attaches and then detach it; for a valid inside invocation, poll until the client switches and then detach it; for an invalid invocation, require a nonzero exit within the bounded timeout while polling for any client, session, or pane change. Capture Bash execution traces from every invocation. | Empty temporary `HOME`, `XDG_CONFIG_HOME`, and `TMUX_TMPDIR`, isolated client `TMUX`, real tmux, `script(1)` with `-e`, FIFO, Bash execution trace, bounded timeout | The first shipped invocation starts the server, creates `default_repo-<short-hostname>` in `default.repo`, and connects the client. The `c` invocation creates `alias_session_blue` in the resolved alias folder, and the repeated `create` invocation reconnects that exact session without changing its identifiers. The `-s`-only and `-c`-only invocations create the expected sessions and pane directories. `prefix-target` is created and reached without reusing `prefix-target-long`. The inside new-session trace records a new `inside_new` session followed by `switch-client -t =inside_new`; the inside reuse trace records no new session and `switch-client -t =alias_session_blue`. Every valid outside invocation connects the client, every valid inside invocation switches the client, and each invalid invocation exits nonzero without state change. No assertion depends on a fixed sleep, and cleanup terminates every PTY, removes every FIFO, and terminates the isolated server. |
| T3 | Attachment integration | Clear inherited `TMUX`, set a temporary `TMUX_TMPDIR`, start `target` with `tmux -f /dev/null new-session -d -s target`, and create separate `source`, `dotted_target_blue`, and `prefix-only-long` sessions on that server. From outside tmux, run `attach -t target`, `attach target`, `a -t target`, and `a target` through separate `script(1)` PTYs and FIFOs with `-e`; poll until each client reaches `target`, then detach it. For each inside-client form, launch a fresh isolated client on `source`, retain that client's `TMUX`, invoke one of the same four forms, poll until the client changes from `source` to `target`, and detach it. Run `attach dotted.target:blue` outside tmux and `a -t dotted.target:blue` from a fresh client on `source`; require both to normalize the input and reach `dotted_target_blue`, then detach. Run each syntax-invalid command `attach`, `a`, `attach -t target target`, `a -t target target`, `attach target extra`, and `a target extra` once outside tmux and once from a fresh client on `source`. Also run `attach prefix-only` outside tmux and `a -t prefix-only` from a fresh client on `source` as valid-shaped missing exact targets. Drive every invocation through its own `script(1)` PTY and FIFO with `-e`; require every failure to exit nonzero within the bounded timeout while polling the client, session identifiers, and pane identifiers for movement or change. Capture Bash execution traces from every shipped-runner invocation against the real isolated tmux server. | Temporary `TMUX_TMPDIR`, controlled tmux config, isolated client `TMUX`, real tmux, `script(1)` with `-e`, FIFO, Bash execution trace, bounded timeout | Exactly `source`, `target`, `dotted_target_blue`, and `prefix-only-long` remain. The standard valid traces record `attach-session -t =target` or `switch-client -t =target` and reach `target`; the normalized valid traces record `attach-session -t =dotted_target_blue` or `switch-client -t =dotted_target_blue` and reach `dotted_target_blue`. Every syntax-invalid trace contains neither `attach-session` nor `switch-client`, exits nonzero, and leaves all state unchanged. The valid-shaped missing-target traces record `attach-session -t =prefix-only` or `switch-client -t =prefix-only`, exit nonzero, do not resolve to `prefix-only-long`, and leave all state unchanged. The `attach` missing-target output reports an error and shows `tmux-runner attach -t <session-name>` and `tmux-runner attach <session-name>`; the `a` missing-target output reports an error and shows `tmux-runner a -t <session-name>` and `tmux-runner a <session-name>`. Cleanup terminates every PTY, removes every FIFO, and terminates the isolated server. |
| T4 | Selection integration | Clear inherited `TMUX` and create two temporary `TMUX_TMPDIR` roots. Under the selected root, start `alpha` with `tmux -f /dev/null new-session -d -s alpha` and then create `gamma`; under the other root, start `beta` with `tmux -f /dev/null new-session -d -s beta`. Set `TMUX_TMPDIR` to the selected root and start the shipped `ls` path through separate `script(1)` PTYs and FIFOs with `-e`. For one bounded outside invocation per selected-root session, poll the captured terminal output for the prompt, derive the displayed number paired with `alpha` or `gamma`, send that number, poll until the client reaches the paired session, and detach it. Launch a fresh isolated client on `alpha`, retain that client's `TMUX`, invoke `ls`, wait for its prompt, derive and send the displayed number for `gamma`, poll until the client switches to `gamma`, and detach it. Run separate bounded outside invocations with nonnumeric input and a number above the displayed range. Capture Bash execution traces from every invocation. | Two temporary `TMUX_TMPDIR` roots, controlled tmux config, isolated client `TMUX`, real tmux, `script(1)` with `-e`, FIFO, captured terminal output, Bash execution trace, bounded timeout | The complete `tmux ls` rows for `alpha` and `gamma` remain visible in every invocation, and no row for `beta` appears. The outside selections reach `alpha` and `gamma` through `attach-session -t =<selected-name>`. The inside selection changes the client from `alpha` to `gamma` through `switch-client -t =gamma`. Invalid input exits nonzero without attaching or switching. No input is sent before the prompt appears, and cleanup terminates both isolated servers, every PTY, and every FIFO. |
| T5 | Bash completion | Clear inherited `TMUX`, load the shipped completion in Bash, and create two temporary `TMUX_TMPDIR` roots. Start `alpha` under the selected root and `beta` under the other root with the first `tmux -f /dev/null new-session -d -s <name>` command for each server, then select the first root with `TMUX_TMPDIR`. Create a completion directory containing directory `work-dir` and nondirectory `work-file`, and run the directory cases from that directory. Before each call to the registered completion function, clear `COMPREPLY` and set one exact input: `COMP_WORDS=(tmux-runner "")` with `COMP_CWORD=1`; `COMP_WORDS=(tmux-runner create -)`, `COMP_WORDS=(tmux-runner c -)`, `COMP_WORDS=(tmux-runner attach -)`, or `COMP_WORDS=(tmux-runner a -)` with `COMP_CWORD=2`; `COMP_WORDS=(tmux-runner create -c work-)` or `COMP_WORDS=(tmux-runner c -c work-)` with `COMP_CWORD=3`; `COMP_WORDS=(tmux-runner attach -t a)` or `COMP_WORDS=(tmux-runner a -t a)` with `COMP_CWORD=3`; and `COMP_WORDS=(tmux-runner attach a)` or `COMP_WORDS=(tmux-runner a a)` with `COMP_CWORD=2`. Compare each resulting `COMPREPLY` as a set. | Bash, temporary directory tree, controlled tmux config, two real isolated tmux servers | The command set is exactly `create`, `c`, `ls`, `attach`, and `a`. The `create` and `c` option set is exactly `-s` and `-c`; the `attach` and `a` option set is exactly `-t`. Each directory context returns exactly `work-dir` and excludes `work-file`. Each session context returns exactly `alpha` and excludes `beta`. Cleanup terminates both isolated servers. |
| T6 | Installation | Clear inherited `TMUX`, create an empty temporary home and an isolated `TMUX_TMPDIR`, and run `make HOME=<temporary-home> install`. Inventory regular files and symbolic links below the temporary home, inspect their modes, compare `bin/tmux-runner` with `<temporary-home>/.local/bin/tmux-runner` using `cmp -s`, and compare `bin/tmux-runner-completion.bash` with `<temporary-home>/.local/share/bash-completion/completions/tmux-runner` using `cmp -s`. Start `install-target` with `tmux -f /dev/null new-session -d -s install-target` as the first command on the isolated server. Run `<temporary-home>/.local/bin/tmux-runner attach -t install-target` through a `script(1)` PTY and FIFO with `-e`; poll until the client reaches `install-target`, detach it, and require the installed runner to exit within the bounded timeout. | Empty temporary `HOME` and `TMUX_TMPDIR`, controlled tmux config, Bash, real tmux, `script(1)` with `-e`, FIFO, bounded timeout | The only regular files or symbolic links below the temporary home are `<temporary-home>/.local/bin/tmux-runner` with mode `0755` and `<temporary-home>/.local/share/bash-completion/completions/tmux-runner` with mode `0644`; both are byte-for-byte identical to their shipped source files. The installed runner reaches `install-target` through the exact target and exits with code 0 after detach. Cleanup terminates the isolated server and PTY and removes the FIFO. |
| T7 | Documentation | Inspect the shipped README against the executable commands, session-name normalization and exact-target behavior, completion behavior, tmux CLI and UDS data flow, and Makefile installation paths. | Repository checkout | The README matches the shipped architecture, functional behavior, session-name normalization and exact-target rules, installation, and data flow without adding out-of-scope behavior or development history. |

##### Verification Results

| Label | Observed At | Environment | Result | Evidence |
| --- | --- | --- | --- | --- |
| T1 | 2026-08-19T22:05:33-07:00 | Debian Linux 6.12.101, Bash 5.2.37, ShellCheck 0.10.0, repository checkout | Pass | Final `tests/test-tmux-runner.bash` run reported `PASS T1`; `bash -n` and ShellCheck returned 0 with no findings. |
| T2 | 2026-08-19T22:05:33-07:00 | Empty temporary `HOME`, `XDG_CONFIG_HOME`, and `TMUX_TMPDIR`; tmux 3.5a; util-linux `script` 2.41.5; real PTYs and FIFOs | Pass | Final suite reported `PASS T2`; shipped create paths, normalization, exact reuse, prefix isolation, inside switching, invalid cases, and cleanup ran through real tmux. |
| T3 | 2026-08-19T22:05:33-07:00 | Temporary `TMUX_TMPDIR`; tmux 3.5a; controlled config; isolated client `TMUX`; real PTYs, FIFOs, and Bash traces | Pass | Final suite reported `PASS T3`; every outside and inside form, normalized target, syntax failure, and missing exact target ran through the shipped runner. |
| T4 | 2026-08-19T22:05:33-07:00 | Two temporary `TMUX_TMPDIR` roots; tmux 3.5a; real PTYs and FIFOs; captured terminal output and Bash traces | Pass | Final suite reported `PASS T4`; complete selected-UDS rows, both outside targets, inside switch, nonnumeric input, and an overflow-sized range error passed. |
| T5 | 2026-08-19T22:05:33-07:00 | Bash 5.2.37, temporary directory tree, two real isolated tmux 3.5a servers | Pass | Final suite reported `PASS T5`; every planned `COMP_WORDS`, `COMP_CWORD`, and `COMPREPLY` set matched exactly. |
| T6 | 2026-08-19T22:05:33-07:00 | Empty temporary `HOME` and `TMUX_TMPDIR`; GNU Make 4.4.1; tmux 3.5a; real PTY and FIFO | Pass | Final suite reported `PASS T6`; only the two expected files were installed with modes `0755` and `0644`, both copies matched, and the installed runner attached exactly. |
| T7 | 2026-08-19T22:05:33-07:00 | Repository checkout plus an empty-home reader execution | Pass | Final suite reported `PASS T7`; a second-person pass also executed installation, `PATH`, and current-shell completion instructions successfully. |

##### Closure Evidence

- 2026-08-19: The first-person retrospective found no remaining scope or implementation item after the selection-overflow and PTY-harness corrections.
- 2026-08-19: The third-person execution review accepted M1 after every syntax-invalid T3 trace and the test dependency list were corrected; independent symlink-directory, cold-error, dry-run, completion-registration, and socket-file checks passed.
- 2026-08-19: The second-person reader pass accepted the README after repository-root, `PATH`, and current-shell completion guidance were added and executed against an empty temporary home.
- 2026-08-19: The final real-path suite completed M1 / T1 through M1 / T7 with seven passes and no remaining external gate.
- Carrying commit: `fa1658ef4cf29c9c781856d84ad1f65da6ff798f` (`Add local tmux session runner`).

## Backlog

### Work

| Group | ID | Work unit | Type | Status | Ready | Deps | Done when / Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |

### Backlog Details

None.
