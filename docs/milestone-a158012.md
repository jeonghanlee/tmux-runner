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

Next session entry point: prepare the accepted M1 correction commit after commit delegation, then record its hash in the closing register update.

## Milestone

### Work

| Group | ID | Work unit | Type | Status | Ready | Deps | Done when / Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Core | M1 | Deliver the local tmux runner | Milestone | In progress | No | D1, D2, D3, D4, D5, D6, D7, D8, D9, D10 | Corrected T1-T8, third-person review, and final second-person reader pass accepted; correction commit pending; [detail](#m1---deliver-the-local-tmux-runner) |

Milestone tally: In progress 1.

### Decisions

| ID | Decision | Decision Date |
| --- | --- | --- |
| D1 | Derive the default session name as `<folder>-<short-hostname>` from the effective starting directory. | 2026-08-19 |
| D2 | Provide `create` and `c`; accept `-s <session-name>` and `-c <folder>`, defaulting to the derived name and current directory. | 2026-08-19 |
| D3 | Attach immediately after creation and attach to an exact-name session when it already exists or appears during a concurrent create. | 2026-08-19 |
| D4 | Provide `attach` and `a`; accept `-t <session-name>`, a positional session name, and `-- <session-name>`. | 2026-08-19 |
| D5 | Make `ls` prefix each complete `tmux ls` row with a selection number and attach to the selected session. | 2026-08-19 |
| D6 | Install only under the user account and provide Bash completion for commands, options, folders, and session names. | 2026-08-19 |
| D7 | Require `attach` and `a` to report an error and show every valid target form when no session target is provided. | 2026-08-19 |
| D8 | Use the tmux CLI as the only session interface: normal runs inherit tmux's selected UDS, test setup clears any inherited `TMUX` and selects an isolated UDS with `TMUX_TMPDIR`, the cold-start test uses empty `HOME` and `XDG_CONFIG_HOME`, prestarted test servers use a first `tmux -f /dev/null` command, inside-client tests use the new client's `TMUX`, and the runner never enumerates socket files directly. | 2026-08-19 |
| D9 | Normalize every CLI-supplied or derived session name by replacing `.` and `:` with `_`, and pass every internal tmux target-session argument as `=<normalized-name>` so lookup and connection require an exact session name. | 2026-08-19 |
| D10 | Provide `-h` and `--help` at the top level and for `create`, `c`, `ls`, `attach`, and `a`; valid help writes to standard output, exits 0, and does not require tmux in `PATH`; do not add a `help` command. | 2026-08-19 |

### Milestone Details

#### M1 - Deliver the local tmux runner

Origin: a158012 / M1
Identity History: none
GitHub Issue: none
Status: In progress

##### Summary

Deliver one small Bash CLI that creates and enters repository-oriented tmux sessions. The effective starting directory supplies the default session name and tmux working directory. The runner normalizes tmux target separators in session names and requires exact session targets. Every session operation uses the tmux CLI to reach the server through tmux's selected UDS; session discovery, selection, and direct attachment share that interface.

##### Scope

- Add `bin/tmux-runner` with `create`, `c`, `ls`, `attach`, and `a` commands.
- Parse tmux-compatible `-s`, `-c`, and `-t` options and reject ambiguous or extra arguments.
- Use `<folder>-<short-hostname>` when `-s` is absent and the current directory when `-c` is absent.
- Normalize CLI-supplied and derived session names by replacing `.` and `:` with `_`.
- Require exact tmux targets for session lookup, reuse, attachment, and switching.
- Attach to an existing exact-name session instead of creating a duplicate, including when another concurrent create wins the creation race.
- Use `switch-client` inside tmux and `attach-session` outside tmux.
- Run session discovery and lifecycle commands through the tmux CLI against tmux's selected UDS without enumerating or parsing socket files.
- Make `attach` and `a` accept the option terminator before a positional target, and exit with an error that shows all valid target forms when no target is provided.
- Make `ls` prefix each complete `tmux ls` row with a selection number before attaching to the selected session.
- Provide dependency-free `-h` and `--help` output at the top level and for every command and alias.
- Add `bin/tmux-runner-completion.bash` for command, option, help option, folder, and live session completion.
- Add a `Makefile` that installs to `~/.local/bin/tmux-runner` and `~/.local/share/bash-completion/completions/tmux-runner` without changing shell startup files.
- Add `tests/test-tmux-runner.bash` and a concise `README.md` describing architecture, requirements, command summary, help, installation preparation, first use, and data flow.

Out of scope: System paths, root access, systemd, configuration files, daemon management, `stop`, `kill`, `rename`, cross-shell completion, tmux window management, and tmux layout management.

##### Completion Criteria

- `create` and `c` normalize `.` and `:` in the session name, create the expected session in the expected directory, and immediately connect or switch the client.
- An existing exact-name target session is reused without creating a duplicate, a prefix-only match is not reused, and concurrent creates both connect to the single exact session.
- `attach` and `a` accept `-t`, positional, and `--`-terminated positional targets and connect or switch to the exact expected session; without a target, they exit nonzero and show all valid forms.
- `ls` queries the server selected through tmux's UDS context, keeps each complete `tmux ls` row visible, prefixes it with a selection number, validates the selection, and connects or switches to the exact selected session.
- Bash completion returns the defined commands, compatible options, folders, and live session names from tmux's selected UDS.
- Top-level and command `-h` and `--help` requests exit 0, write usage to standard output without an error, and work when tmux is absent from `PATH`.
- `make install` writes exact copies of the two shipped artifacts only, including when `HOME` contains spaces, with mode `0755` for the runner and `0644` for the completion.
- The README describes only the shipped architecture, requirements, functional behavior, help, installation, first use, and data flow.
- M1 / T1 through M1 / T8 record passing results from the real shipped files and real process paths.

##### Dependencies And Decisions

- D1, D2, D3, D4, D5, D6, D7, D8, D9, and D10.

##### Implementation Plan

Plan Status: accepted
Plan Acceptance: 2026-08-19
Implementation Authorization: 2026-08-19 - full M1 implementation authorized
Superseded Plan Artifacts: none

1. Create `bin/tmux-runner` with dependency-free top-level and command help, command validation, option parsing, directory resolution, session-name derivation, `.` and `:` normalization, exact target construction, and a shared tmux CLI path that inherits tmux's selected UDS context.
2. Implement `create` and `c`, including exact existing-session reuse, concurrent-create recovery, default attachment, and tmux-client switching.
3. Implement attach target validation including `--`, usage guidance, full-row interactive list selection, and shared attachment logic.
4. Create `bin/tmux-runner-completion.bash` with context-sensitive command, option, help option, directory, and session completion.
5. Create the local-only `Makefile`; make its `install` target resolve quoted destination directories from `$(HOME)/.local`, accept a command-line `HOME` override including paths with spaces, install the runner with mode `0755`, install the completion with mode `0644`, and leave shell startup files unchanged.
6. Create `tests/test-tmux-runner.bash`; clear inherited `TMUX`, select each isolated UDS with `TMUX_TMPDIR`, use empty `HOME` and `XDG_CONFIG_HOME` for the shipped `create` cold start, start precreated servers with a first `tmux -f /dev/null` command, retain the isolated client's `TMUX` for inside-client checks, and exercise the shipped CLI through a real tmux server, `script(1)` PTYs fed by FIFOs, `script -e` child-status propagation, monitor readiness handshakes, continuous state polling, bounded timeouts, process-group cleanup, and Bash execution traces.
7. Replace the placeholder README with the shipped architecture, requirements, command summary, help, functional behavior, session-name normalization and exact-target rules, installation preparation, first use, and data flow, then inspect it against the shipped files.

##### Test Plan

| Label | Layer | Method | Environment | Expected Result |
| --- | --- | --- | --- | --- |
| T1 | Static | Run `bash -n` and ShellCheck on the shipped runner, completion, and test scripts. | Repository checkout | All files pass with exit code 0 and no findings. |
| T2 | CLI integration | Exercise default, alias, `-s`-only, `-c`-only, normalized reuse, prefix isolation, and inside-client create paths through separate real `script(1)` PTYs. Start two additional PTYs behind one readiness barrier and release `create -s concurrent-session -c <concurrent-folder>` simultaneously. Require both traces to reach `new-session`, one trace to record a failed create followed by an exact `has-session` recheck, and both clients to reach the single exact session. Run each invalid create separately after a monitor has completed its first clean sample; until process exit, compare session, window, and pane identifiers plus client PID, TTY, and session, and treat any tmux query failure as a test failure. | Empty temporary `HOME`, `XDG_CONFIG_HOME`, and `TMUX_TMPDIR`; isolated client `TMUX`; real tmux; `script(1)` with `-e`; FIFOs; readiness files; Bash traces; bounded timeouts | All expected sessions use normalized exact names and expected directories. Exact reuse preserves identifiers, prefix-only names remain distinct, inside runs use `switch-client`, and both concurrent runs exit 0 after reaching one `concurrent-session`. Each invalid form exits nonzero without lifecycle calls or any observed state change. Cleanup closes tracked FDs, terminates PTY process groups, and terminates the isolated server. |
| T3 | Attachment integration | On one controlled isolated server, run `attach -t target`, `attach target`, `attach -- target`, `a -t target`, `a target`, and `a -- target` once outside and once inside tmux. Exercise normalized names and missing exact prefix targets. Run missing, mixed, extra, and `-- target extra` syntax failures for both command names outside and inside. Begin each failure only after the continuous state monitor reports its first clean sample, then poll session, window, pane, client PID, client TTY, and client session identity until exit. Capture every shipped-runner Bash trace. | Temporary `TMUX_TMPDIR`; controlled tmux config; isolated client `TMUX`; real tmux; `script(1)` PTYs and FIFOs; readiness files; Bash traces; bounded timeouts | Every valid form reaches the exact target through `attach-session` or `switch-client`; normalized names reach the normalized exact session. Every syntax failure contains no attach or switch call, reports all supported target forms when missing, exits nonzero, and has no observed state change. Missing exact targets do not resolve to longer prefix matches. |
| T4 | Selection integration | Create selected and other isolated UDS roots, with `alpha` and `gamma` only on the selected server and `beta` only on the other. Exercise outside selection of both selected sessions and inside switching from `alpha` to `gamma` through real PTYs. For nonnumeric and overflow-sized input, start the identity monitor and wait for its first clean sample before starting the runner, then keep it active through process exit. | Two temporary `TMUX_TMPDIR` roots; controlled tmux config; isolated client `TMUX`; real tmux; `script(1)` PTYs and FIFOs; captured output; Bash traces; bounded timeouts | Complete selected-server rows remain visible, `beta` never appears, exact selections attach or switch correctly, and both invalid inputs exit nonzero without any observed session, pane, or client change. |
| T5 | Bash completion | Load the shipped completion against two isolated real servers and compare exact `COMPREPLY` sets for commands, top-level and command help options, command options, directories, `-t` targets, positional targets, and targets following `--`, for both long and alias commands. Include a selected-UDS session named `-dash` and request it after both `-t` and `--`. | Bash; temporary directory tree; controlled tmux config; two real isolated tmux servers | Command and option sets match the supported CLI, every command exposes `-h` and `--help`, directory completion excludes files, and every `-t`, positional, or `--` target context returns only matching selected-UDS sessions, including `-dash`. |
| T6 | Installation | Set `HOME` to an empty temporary directory whose name contains spaces and run `make HOME=<temporary-home> install`. Inventory files and links, inspect modes, compare both installed artifacts byte for byte, then execute the installed runner through a real PTY against an isolated tmux server. | Spaced temporary `HOME`; temporary `TMUX_TMPDIR`; controlled tmux config; GNU Make; real tmux; `script(1)` PTY and FIFO; bounded timeout | Exactly the runner at mode `0755` and completion at mode `0644` are installed under the spaced home, both match their shipped sources, and the installed runner attaches to the exact target and exits 0. |
| T7 | Documentation | Inspect the shipped README against the executable commands, requirement paths and versions, command summary, help, session-name normalization and exact-target behavior, completion behavior, tmux CLI and UDS data flow, Makefile installation paths, current-shell `PATH` and completion preparation, first use including detach, and quoted `HOME` override examples. | Repository checkout | The README matches the shipped architecture, requirements, functional behavior, help, session-name normalization and exact-target rules, installation, first use, and data flow; its install and dry-run examples preserve a `HOME` path containing spaces. |
| T8 | CLI help | Invoke the shipped runner with `-h` and `--help` at the top level and after `create`, `c`, `ls`, `attach`, and `a` while `PATH` contains neither tmux nor hostname. Capture standard output, standard error, and exit status for every form, then run top-level help with an extra argument. | Bash; shipped runner; dependency-free `PATH`; captured output and status | Every valid help form exits 0, writes the matching usage and help options to standard output, writes nothing to standard error, and never reports a tmux dependency error. Help with an extra argument exits 2 with its own argument error before dependency validation. |

##### Verification Results

| Label | Observed At | Environment | Result | Evidence |
| --- | --- | --- | --- | --- |
| T1 | 2026-08-20T00:06:54-07:00 | Debian Linux 6.12.101, Bash 5.2.37, ShellCheck 0.10.0, repository checkout | Pass | Help enhancement suite reported `PASS T1`; `bash -n`, ShellCheck, and `git diff --check` returned 0 with no findings. |
| T2 | 2026-08-20T00:06:54-07:00 | Empty temporary `HOME`, `XDG_CONFIG_HOME`, and `TMUX_TMPDIR`; tmux 3.5a; util-linux `script` 2.41.5; real PTYs, FIFOs, readiness files, and Bash traces | Pass | Help enhancement suite reported `PASS T2`; create, exact reuse, concurrent recovery, invalid forms, and inside switching remained correct. |
| T3 | 2026-08-20T00:06:54-07:00 | Temporary `TMUX_TMPDIR`; tmux 3.5a; controlled config; isolated client `TMUX`; real PTYs, FIFOs, readiness files, and Bash traces | Pass | Help enhancement suite reported `PASS T3`; every outside and inside attachment form and monitored failure remained correct. |
| T4 | 2026-08-20T00:06:54-07:00 | Two temporary `TMUX_TMPDIR` roots; tmux 3.5a; real PTYs, FIFOs, continuous state monitors, captured output, and Bash traces | Pass | Help enhancement suite reported `PASS T4`; complete selected-UDS rows, valid selection, and invalid input handling remained correct. |
| T5 | 2026-08-20T00:06:54-07:00 | Bash 5.2.37, temporary directory tree, two real isolated tmux 3.5a servers | Pass | Help enhancement suite reported `PASS T5`; exact completion sets included top-level and per-command `-h` and `--help` plus every existing option, directory, and selected-UDS session case. |
| T6 | 2026-08-20T00:06:54-07:00 | Spaced temporary `HOME`; empty temporary `TMUX_TMPDIR`; GNU Make 4.4.1; tmux 3.5a; real PTY and FIFO | Pass | Help enhancement suite reported `PASS T6`; the exact installed copies and modes remained correct, and the installed runner attached exactly. |
| T7 | 2026-08-20T00:06:54-07:00 | Repository checkout plus spaced-home installation and real isolated tmux UDS | Pass | Help enhancement suite reported `PASS T7`; the README covered requirement paths and versions, command summary, help, installation preparation, first use and detach, and the existing architecture and data flow. |
| T8 | 2026-08-20T00:06:54-07:00 | Bash 5.2.37; shipped runner; dependency-free `PATH`; captured standard output, standard error, and status | Pass | All 12 top-level, command, and alias `-h` and `--help` forms exited 0 on standard output without tmux in `PATH`; the extra-argument case exited 2 with its own error before dependency validation. |

##### Closure Evidence

- 2026-08-19: The first-person retrospective found no remaining scope or implementation item after the selection-overflow and PTY-harness corrections.
- 2026-08-19: The third-person execution review accepted M1 after every syntax-invalid T3 trace and the test dependency list were corrected; independent symlink-directory, cold-error, dry-run, completion-registration, and socket-file checks passed.
- 2026-08-19: The second-person reader pass accepted the README after repository-root, `PATH`, and current-shell completion guidance were added and executed against an empty temporary home.
- 2026-08-19: The final real-path suite completed M1 / T1 through M1 / T7 with seven passes and no remaining external gate.
- Carrying commit: `fa1658ef4cf29c9c781856d84ad1f65da6ff798f` (`Add local tmux session runner`).
- 2026-08-19: A new third-person review reopened M1 after finding a spaced-`HOME` install failure, incomplete invalid-state polling, a concurrent-create race, broken `attach -- <session>` handling, and missing test dependency checks; T1-T7 replacement evidence is required.
- 2026-08-19: The correction suite passed T1-T7 through the shipped files, real tmux, isolated UDS roots, PTYs, FIFOs, readiness handshakes, continuous state monitors, and a spaced temporary `HOME`.
- 2026-08-19: The third-person follow-up accepted the concurrent exact recheck and leading-dash completion corrections after a stable full-suite pass; pre-run and post-run file hashes matched and no test process or workspace remained.
- 2026-08-19: The correction first-person retrospective found no remaining implementation or scope gap after all five reopened findings and the third-person follow-up findings were corrected.
- 2026-08-19: The second-person reader pass accepted the corrected README and canonical record after independently executing spaced-home installation, PATH lookup, completion registration, exact `--` attachment for normal and leading-dash names, and T1-T7.
- 2026-08-19: A standalone second-person review found that the test-home install examples omitted quotes, causing a substituted spaced path to become extra Make targets; the accepted finding added quotes and T7 regression checks.
- 2026-08-19: The second-person follow-up accepted the quoted examples after the dry run preserved every spaced path, the real install produced the exact two expected files with modes `0755` and `0644`, and the updated T1-T7 suite passed.
- 2026-08-19: A further third-person review accepted the corrected behavior and verification but returned M1 to `In progress` because the correction commit remains pending.
- 2026-08-19: A full documentation and CLI audit found no conventional help path, incomplete installation preparation, and no first-use sequence; D10 and M1 / T8 record the accepted flag-only help enhancement and its verification.
- 2026-08-19: The help enhancement suite passed T1-T8 through the shipped CLI, completion, README, real tmux UDS and PTY paths, spaced-home installation, and dependency-free help path.
- 2026-08-20: The independent third-person review accepted the enhancement after installed-copy help, option-looking session attachment, completion collision, spaced-home installation, first-use, and exact-reuse probes returned no finding.
- 2026-08-20: The second-person reader pass found that First Use omitted the detach step required before exact reuse and that the requirement checks did not verify Bash or GNU Make versions; the accepted corrections add both reader-visible steps.
- 2026-08-20: A fresh second-person reader accepted the corrected README after executing requirement version checks, installation, `PATH`, completion, create, documented detach, and exact reuse without another finding.
- Correction commit: pending commit delegation.

## Backlog

### Work

| Group | ID | Work unit | Type | Status | Ready | Deps | Done when / Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |

### Backlog Details

None.
