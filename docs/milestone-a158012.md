# Work Register

## Scope

This document tracks delivery and extension of the local-only `tmux-runner`
CLI, its dedicated tmux server, repository-oriented navigation, Bash
completion, installation, and verification.

**Out of scope:** System-wide installation, service supervision, Git tag
creation or push, GitHub release execution, GitHub projection, and tmux window
or layout management.

Release line: master
Milestone index: a158012
Canonical path: `docs/milestone-a158012.md`
Canonical branch or ref: master
Git upstream: origin/master
Remote tracker: none

Next session entry point: record the M6 carrying commit, then implement M7
against the accepted plan in this document.

## Milestone

### Work

| Group | ID | Work unit | Type | Status | Ready | Deps | Done when / Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Core | M1 | Deliver the local tmux runner | Milestone | Complete | No | D1, D2, D3, D4, D5, D6, D7, D8, D9, D10 | Complete 2026-08-20, correction commit `ede2b62`; corrected T1-T8, third-person review, and final second-person reader pass accepted; [detail](#m1---deliver-the-local-tmux-runner) |
| Version | M2 | Add source and installed version identity | Milestone | Complete | No | M1, D11, D12 | Complete 2026-08-23, carrying commit `88d20a4`; M2 / T1-T5, shipped suite T1-T9, and the stage review cycle accepted; [detail](#m2---add-source-and-installed-version-identity) |
| Server | M3 | Isolate the runner server and local tmux configuration | Milestone | Complete | No | M2, D13, D14, D17 | Complete 2026-08-24, carrying commit `89095fb`; M3 / T1-T5 and both requested reviews accepted; [detail](#m3---isolate-the-runner-server-and-local-tmux-configuration) |
| Identity | M4 | Resolve repository and working-directory identity | Milestone | Complete | No | M3, D16 | Complete 2026-08-24, carrying commit `8caaea1`; M4 / T1-T5 and both requested reviews accepted; [detail](#m4---resolve-repository-and-working-directory-identity) |
| Discovery | M5 | Discover configured repositories and select one | Milestone | Complete | No | M4, D15, D17 | Complete 2026-08-24, carrying commit `71ce91f`; M5 / T1-T5 and both requested reviews accepted; [detail](#m5---discover-configured-repositories-and-select-one) |
| Navigation | M6 | Add recent and previous-session navigation | Milestone | In progress | No | M5, D18 | Implementation, M6 / T1-T5, and the third-person review are complete; the completion mark rides the M7 update; [detail](#m6---add-recent-and-previous-session-navigation) |
| Integration | M7 | Complete integrated verification and release preparation | Milestone | Not started | No | M3, M4, M5, M6, D17 | Starts after M3-M6; [detail](#m7---complete-integrated-verification-and-release-preparation) |

Milestone tally: Complete 5, In progress 1, Not started 1.

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
| D11 | Set the runner version to `0.1.0`; add the `epics-ioc-runner` source and installed metadata behavior without copying its modular Make structure; keep the version value only in `bin/tmux-runner`, resolve live Git identity for source runs, and inject Git hash, commit date, and install date into the user-installed copy. | 2026-08-22 |
| D12 | Use the proven `epics-ioc-runner` content comparison, `git diff --quiet HEAD --`, for both live and installed dirty-state detection; verify relocated clean, modified, and read-only-index copies through real Git. | 2026-08-22 |
| D13 | Starting with M3, supersede D8's inherited server selection: route every runner tmux operation to the named server selected by `-L tmux-runner`; keep it separate from the default tmux server, do not migrate or list default-server sessions, and load the runner configuration only when the dedicated server starts. D8 remains the completed M1 contract. | 2026-08-23 |
| D14 | Starting with M3, narrow the M1 inside-client behavior: inside the dedicated server, enter another runner session with `switch-client`; inside any other tmux server, return an error without changing state and direct the user to detach and rerun from the outer shell. | 2026-08-23 |
| D15 | Add `tmux-runner repo` for configured repository discovery and numbered create-or-attach selection; keep `tmux-runner ls` limited to sessions on the dedicated server. | 2026-08-23 |
| D16 | Starting with M4, supersede D1 for Git working trees while preserving D1 for non-Git directories. For an automatically derived name, use `<repo>-<short-hostname>` when the canonical repository name is unique and prepend the minimum distinguishing parent path on a known collision. If distinct paths still normalize to one name, append a deterministic canonical-path SHA-256 suffix, beginning with 12 hexadecimal characters and extending it if required. Store the canonical path in `@tmux-runner-path` and use path identity before an automatically derived name. Preserve explicit `-s` as name-directed: allow more than one explicit name for one path, but fail instead of choosing among multiple path matches or reusing an occupied name whose path is missing or different. | 2026-08-23 |
| D17 | Read repository search roots from `${XDG_CONFIG_HOME:-$HOME/.config}/tmux-runner/repos` as one absolute path per line without shell evaluation; ignore blank lines and full-line comments, canonicalize and deduplicate roots, and warn and skip missing roots. Keep tmux settings in the adjacent `tmux.conf`. | 2026-08-23 |
| D18 | Add a 20-entry recent path list and previous-session navigation under `${XDG_STATE_HOME:-$HOME/.local/state}/tmux-runner`. Record only path-marked sessions in `recent`, allow any successfully entered runner session in `last`, serialize and atomically replace state, and ignore stale records safely. After a successful `switch-client`, update state. For blocking outside attach, stage a transaction and use a server-side acknowledgment after client attachment; commit an acknowledged transaction even if the client later exits abnormally, roll back only an unacknowledged failure, and reconcile orphan transactions on the next state access. | 2026-08-23 |

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
- Correction commit: `ede2b62c478b0f7d87a93c7c55b5ee0323740abf` (`Harden tmux runner behavior and help`).

#### M2 - Add source and installed version identity

Origin: a158012 / M2
Identity History: none
GitHub Issue: none
Status: Complete

##### Summary

Give the source runner and its user-installed copy one observable version
contract. Source execution resolves the current Git identity without changing
the repository, while installation stamps immutable Git and UTC date metadata
into the copied runner.

##### Scope

- Set version `0.1.0` in `bin/tmux-runner` as the single version value.
- Add dependency-free `-V` and `--version` forms with version, Git hash,
  commit date, and install date output.
- Mark source checkout output as live and add `-dirty` when tracked content
  differs from `HEAD`.
- Use `git diff --quiet HEAD --` so relocated clean checkouts and read-only
  indexes retain a bare hash while real tracked changes remain dirty.
- Add `configure/inject-runner-version.bash` to stamp the installed copy.
- Invoke the injector from the existing local `make install` path without
  adding another installed file.
- Extend Bash completion, README requirements and usage, and the real-path
  test suite for source and installed metadata.

Out of scope: Git tag creation, GitHub release execution, a modular
`configure/` Make system, copying `configure/RELEASE`, untracked-file dirty
detection, and changing the existing tmux session behavior.

##### Completion Criteria

- `tmux-runner -V` and `tmux-runner --version` return the same three-line
  output and report version `0.1.0` before tmux dependency validation.
- Relocated clean and read-only-index Git fixtures report their bare short
  hash with `(live)`, while a real tracked modification adds `-dirty`.
- A user-installed copy reports the source hash without `(live)`, the source
  commit date in UTC, and an installation timestamp within the install run.
- Installation still writes only the runner and completion files with the
  existing modes, and the installed runner differs from the source only in
  the three injected metadata declarations.
- Help, completion, README, static checks, and the existing tmux UDS and PTY
  behavior all pass through the shipped files.

##### Dependencies And Decisions

- M1, D11, and D12.

##### Implementation Plan

Plan Status: accepted
Plan Acceptance: 2026-08-22 - selected the source and installed metadata
behavior without the modular Make structure, then selected version `0.1.0`.
Implementation Authorization: 2026-08-22 - requested that the selected
version-management behavior be copied into this repository.
Superseded Plan Artifacts: none

1. Add one version value and three injectable metadata declarations to the
   runner, then implement strict `-V` and `--version` handling before tmux
   validation.
2. Add a user-mode metadata injector and call it after the runner copy in
   `make install`.
3. Extend completion, README, and the existing integration suite with
   relocated clean, modified, and read-only-index Git fixtures plus
   installed-copy verification.
4. Run the complete shipped suite, perform the stage review cycle, and record
   the carrying commit in the next milestone update.

##### Test Plan

| Label | Layer | Method | Environment | Expected Result |
| --- | --- | --- | --- | --- |
| T1 | Static | Run Bash syntax checks and ShellCheck on the runner, completion, injector, and test suite. | Repository checkout | Every shipped Bash file returns 0 with no finding. |
| T2 | Source identity | Execute both version forms from an unrelated directory, then commit the shipped runner once and copy that Git repository without another Git operation into clean, modified, and read-only-index fixtures. | Real Git repository with relocated copies and copied shipped runner | Both forms agree; relocated clean and read-only-index runners use a bare live hash, while the modified runner adds `-dirty`. |
| T3 | Installed identity | Run the shipped Makefile into a spaced temporary home and run the injector against relocated clean, modified, and read-only-index real Git fixtures. | Temporary home and real relocated Git fixtures | The installed copy retains version `0.1.0`; clean and read-only-index copies use the bare source hash, the modified copy uses `-dirty`, and commit and install dates remain correct without changing non-metadata content. |
| T4 | Dependency boundary | Run version output and invalid version syntax with neither tmux, hostname, Git, nor date in `PATH`. | Dependency-free `PATH` with `/bin/bash` | Valid version output returns 0 with fallback metadata; extra arguments return 2 with the version syntax error before tmux validation. |
| T5 | Regression integration | Run the complete shipped test suite through real isolated tmux servers, UDS roots, PTYs, installation, completion, documentation, and Git fixtures. | Linux user environment with real tmux, Git, GNU Make, and `script(1)` | Existing behavior and all version paths pass, and cleanup leaves no test server or workspace. |

##### Verification Results

| Label | Observed At | Environment | Result | Evidence |
| --- | --- | --- | --- | --- |
| T1 | 2026-08-22T13:39:43-07:00 | Repository checkout with Bash 5.2 and ShellCheck 0.10.0 | Pass | The final-state suite reported `PASS T1`; Bash syntax checks and ShellCheck returned 0 for the runner, completion, injector, and test script. |
| T2 | 2026-08-22T13:39:43-07:00 | Source checkout plus relocated clean, modified, and read-only-index real Git fixtures | Pass | `-V` and `--version` agreed from an unrelated directory; relocated clean and read-only-index copies reported the bare hash with `(live)`, while the tracked modification reported `-dirty (live)`. |
| T3 | 2026-08-22T13:39:43-07:00 | Spaced temporary home plus relocated clean, modified, and read-only-index real Git fixtures | Pass | The final-state suite reported `PASS T6` and `PASS T9`; installed copies retained the expected bare or dirty hash, source commit date, in-range install date, file modes, and non-metadata content. |
| T4 | 2026-08-22T13:39:43-07:00 | `/bin/bash` with dependency-free `PATH` | Pass | Version `0.1.0` printed with fallback metadata and exit 0; an extra argument returned 2 with the version syntax error before tmux validation. |
| T5 | 2026-08-22T13:39:43-07:00 | Real tmux 3.5a servers, isolated UDS roots, PTYs, relocated Git fixtures, and spaced-home installation | Pass | The shipped suite reported `PASS T1` through `PASS T9` and `PASS: 9 milestone checks completed`; no test server or workspace remained. |

##### Closure Evidence

- 2026-08-22: The first-person retrospective confirmed the selected version
  and install scope after metadata-anchor failures were made explicit.
- 2026-08-22: The third-person execution review accepted the source and
  installed Git comparison after relocated clean, modified, and read-only-index
  fixtures passed through the real shipped paths.
- 2026-08-22: The second-person reader pass accepted the README after its
  requirement checks, dry run, spaced-path installation, installed version,
  file modes, and completion registration all matched a new temporary home.
- Carrying commit: `88d20a454a28dd85c3318bf3a84fdf372afab8ff`
  (`Add version identity to tmux runner`).

#### M3 - Isolate the runner server and local tmux configuration

Origin: a158012 / M3
Identity History: none
GitHub Issue: none
Status: Complete

##### Summary

Move every runner session operation to one dedicated tmux named server. Keep
its sessions and configuration independent from the user's default tmux
server while preserving the existing command behavior inside that boundary.

##### Scope

- Route every runner tmux command through `tmux -L tmux-runner` while
  preserving the active `TMUX_TMPDIR` socket root.
- Keep `create`, `c`, `ls`, `attach`, `a`, and Bash completion on the same
  dedicated server path.
- Read `${XDG_CONFIG_HOME:-$HOME/.config}/tmux-runner/tmux.conf` only when the
  dedicated server starts; start with `-f /dev/null` when the file is absent so
  system and general user tmux configuration cannot enter the runner server.
- Ship `config/tmux.conf` as a valid no-op starter file that imposes no status
  layout or key binding. Install it at the runner config path with mode `0644`
  only when that destination does not already exist.
- Make configuration changes take effect on the next dedicated-server start,
  without restarting or changing the default tmux server.
- Continue to use `switch-client` inside the dedicated server.
- Detect a client connected to any other tmux server, exit nonzero without a
  tmux or state change, and show the detach-then-rerun instruction.
- Perform the other-server check after dependency-free help and version output
  but before any dedicated-server query, creation, configuration, or state
  operation. Compare the socket field in `TMUX` with the expected `-L` socket
  path under the effective `TMUX_TMPDIR`.
- Update help, completion, README architecture, and the real tmux test harness
  for the dedicated server and isolated configuration path.

Out of scope: Moving existing default-server sessions, controlling the default
server, automatically restarting a running server after configuration changes,
and prescribing a site-specific status layout or key map.

##### Completion Criteria

- Runner-created sessions appear only on the `tmux-runner` named server, and
  default-server sessions never appear in `tmux-runner ls` or completion.
- Every lifecycle, query, completion, and cleanup path selects the dedicated
  server; no command silently falls back to the default server.
- A temporary runner `tmux.conf` changes real server options and key bindings
  on first start, remains unchanged while that server runs, and is reread after
  only the dedicated server is stopped and started again.
- With no runner config, neither system nor general user tmux settings appear
  on the dedicated server. Local installation copies the no-op starter config
  with mode `0644` and never changes an existing destination.
- A runner client switches between runner sessions, while a client on another
  server receives the detach instruction before a cold runner socket is
  created and leaves both servers unchanged.
- The full existing command, installation, help, and version behavior passes
  after the server boundary changes, with no test socket or process left over.

##### Dependencies And Decisions

- M2, D13, D14, and D17.

##### Implementation Plan

Plan Status: accepted
Plan Acceptance: 2026-08-23 - accepted the staged roadmap and dedicated-server
behavior.
Implementation Authorization: 2026-08-24 - full M3 implementation authorized
Superseded Plan Artifacts: none

1. Centralize the tmux command prefix and server identity so every runner and
   completion call uses the same named server and socket root.
2. Add first-start configuration selection, the no-op starter config, and
   non-overwriting local installation.
3. Detect the current tmux socket before any mutable path, preserve
   dedicated-server switching, and add the no-change error path for a client
   on another server.
4. Extend the test harness with dual-server monitors and an outer supervisor
   that can inspect cleanup after the suite process exits. Successful runs
   remove test resources; failed runs terminate processes but preserve and
   report the diagnostic workspace.
5. Update help, completion, and README text that changes in this milestone,
   then run the complete shipped suite and the stage review cycle.

##### Test Plan

| Label | Layer | Method | Environment | Expected Result |
| --- | --- | --- | --- | --- |
| T1 | Static | Run Bash syntax checks and ShellCheck, then inspect every shipped tmux invocation and completion query for the centralized named-server path. | Repository checkout | All shipped Bash files pass, and no runner operation bypasses the dedicated-server command path. |
| T2 | Server integration | Start a default server and the `tmux-runner` named server under one temporary socket root; create, list, attach, and complete sessions through the shipped runner and query both servers directly. | Real tmux, temporary `TMUX_TMPDIR`, real PTYs and FIFOs | Each server sees only its own sessions and clients, and every runner operation reaches only the named server. |
| T3 | Configuration integration | Put a marker in general `~/.tmux.conf`, start once with no runner config, then start with a temporary XDG runner config that sets a different marker, status option, and key binding; change the runner file while its server runs, then stop and restart only that server. Install the starter config twice around a local modification. | Real tmux, temporary `HOME`, `XDG_CONFIG_HOME`, and `TMUX_TMPDIR` | The absent-config start uses isolated defaults; runner values load only on server start and reload only after restart; the default server remains unchanged; and installation creates mode `0644` once without overwriting the modified config. |
| T4 | Client-boundary integration | Run shipped commands in real dedicated and default-server clients while a dual-server monitor observes both. Repeat the default-client rejection before any named server exists. | Real tmux clients, `script(1)` PTYs, readiness barriers, dual-server state monitor, bounded timeouts | Dedicated clients switch successfully; other-server clients receive the detach instruction and exit nonzero without session, pane, client, or cold-socket creation. Help and version remain dependency-free. |
| T5 | Regression and cleanup | Run the complete shipped suite with help, version, completion, installation, create, attach, list, and concurrent-create cases under an outer supervisor that receives the workspace and process manifest. | Isolated real tmux and Git environment plus supervisor process | All existing contracts pass. After a passing child exits, the supervisor observes no named or default test server, socket, PTY process, or workspace; a forced failing child terminates processes and preserves and reports its diagnostic workspace. |

##### Verification Results

| Label | Observed At | Environment | Result | Evidence |
| --- | --- | --- | --- | --- |
| T1 | 2026-08-24 | Repository checkout; Bash and ShellCheck | Pass | The shipped scripts passed syntax and ShellCheck; static inspection found one centralized executable tmux invocation and the dedicated completion query. |
| T2 | 2026-08-24 | Real default and named tmux servers under one `TMUX_TMPDIR`; PTYs and completion subprocess | Pass | Create, list, attach, and completion reached only the named server while the default-server snapshot remained unchanged. |
| T3 | 2026-08-24 | Temporary `HOME`, XDG config, real tmux options and key table, repeated named-server starts | Pass | General config was excluded; runner marker, status, and key values loaded only at server start; named-only restart reloaded them; install preserved a modified config. |
| T4 | 2026-08-24 | Real default-server client, cold named socket, dual-server monitor, PTY | Pass | The mutable command failed with detach guidance before socket creation; help and version succeeded; both server snapshots remained unchanged. |
| T5 | 2026-08-24 | Full shipped T1-T9 and M3 T1-T4 child plus forced-failure child under outer supervisor | Pass | Existing behavior passed; the passing child left no tracked process, socket, or workspace; the forced failure stopped processes and sockets, reported and preserved its workspace, and the supervisor removed it after inspection. |

##### Closure Evidence

- `tests/test-tmux-runner.bash` passed the existing T1-T9 checks, M3 / T1-T4,
  and the outer-supervisor M3 / T5 check on 2026-08-24.
- The 2026-08-24 third-person review accepted M3 after narrowing the README
  other-server statement to session commands; its independent shipped-suite
  run and `git diff --check` passed.
- The 2026-08-24 second-person review accepted M3 after aligning help, test
  installation paths, install output, and the remaining detach instruction.
- Carrying commit: `89095fb`.

#### M4 - Resolve repository and working-directory identity

Origin: a158012 / M4
Identity History: none
GitHub Issue: none
Status: Complete

##### Summary

Make a Git working tree, a linked worktree, and a normal directory resolve to
stable runner identities. Use canonical paths to prevent a same-name session
from being reused for the wrong location.

##### Scope

- Resolve a path inside a Git working tree to that working tree's top-level
  directory before deriving its default session identity.
- Treat each linked worktree as its own working directory, including the
  `.git` file form used by real linked worktrees.
- Preserve the existing directory basename behavior outside Git.
- Store each runner-managed canonical path in the session option
  `@tmux-runner-path`.
- When `-s` is absent, look for an exact canonical-path match before deriving
  or comparing a session name.
- Use `<repo>-<short-hostname>` when available; when an active path-marked
  session exposes a same-basename collision, prepend only enough parent
  components to produce a distinct normalized session name.
- If all distinguishing parent components still collide after D9
  normalization, append a stable SHA-256 prefix of the canonical path. Begin
  with 12 hexadecimal characters and extend the prefix only if an occupied
  different path still collides.
- Create a session and its `@tmux-runner-path` option in one tmux command
  queue. After a concurrent name loss, verify the winner's path; reuse it only
  on an exact path match, otherwise extend the parent prefix and retry.
- Keep explicit `-s` name-directed. The same canonical path may have multiple
  explicit session names; an occupied explicit name is reused only when its
  path option matches, and a missing or different path option produces an
  error without an alternate name.
- If an automatically named request finds more than one session carrying the
  same canonical path, fail without choosing one and list the exact matching
  session names for direct attachment.
- Extend completion, help, README identity examples, and real Git fixtures.

Out of scope: Remote repository URLs, branch-based session names, renaming an
existing session when a later collision appears, and repository discovery.

##### Completion Criteria

- Two subdirectories of one real Git working tree resolve to one session with
  the repository root as its tmux working directory.
- Two different repositories with the same basename never share a session;
  the later collision uses the minimum parent-path prefix needed to distinguish
  it without renaming an existing session.
- A main working tree and a real linked worktree resolve to different canonical
  paths, sessions, and tmux working directories.
- A normal non-Git directory retains `<folder>-<short-hostname>` and its own
  canonical working directory.
- An automatically named request reuses an exact canonical-path match even
  when that session was created with an explicit or disambiguated name.
- An explicit name preserves the existing ability to create multiple sessions
  for one path, while an occupied explicit name with a different or missing
  path option fails without wrong-path reuse.
- Simultaneous creates for two different same-basename paths finish with two
  correctly marked sessions; neither client enters the other path.
- Parent components that become equal after D9 normalization still produce
  stable distinct session names through the canonical-path suffix.
- After two explicit names are created for one path, an automatically named
  request reports both exact names and changes no tmux state.
- Existing create, attach, exact-target, concurrency, and dedicated-server
  behavior remains valid.

##### Dependencies And Decisions

- M3 and D16.

##### Implementation Plan

Plan Status: accepted
Plan Acceptance: 2026-08-23 - accepted repository-root, linked-worktree,
collision, and normal-directory identity behavior.
Implementation Authorization: 2026-08-24 - full M4 implementation authorized
Superseded Plan Artifacts: none

1. Add canonical working-path and Git top-level resolution without replacing
   Git behavior with a hand-built `.git` parser.
2. Add derived-name path lookup and name-directed explicit behavior, including
   errors for occupied unmarked or differently marked explicit targets.
3. Add minimum-parent collision naming and one-queue session-plus-option
   creation; after a create race, verify the winner's path before reuse or
   retry with a longer name.
4. Add deterministic SHA-256 fallback naming and explicit ambiguous-path
   rejection, then add real repository, linked-worktree, collision, and
   normal-directory fixtures to the dedicated-server test harness.
5. Update changed help, completion, and README sections, then run the complete
   shipped suite and the stage review cycle.

##### Test Plan

| Label | Layer | Method | Environment | Expected Result |
| --- | --- | --- | --- | --- |
| T1 | Repository identity | Create one real Git repository and enter it from two different subdirectories through the shipped runner. | Real Git repository, real named tmux server, PTYs | Both entries reuse one path-marked session whose pane starts at the Git top level. |
| T2 | Collision identity | Create real repositories with the same basename under parents that require one, two, and three distinguishing components; include distinct paths whose parent components become identical after D9 normalization. Retain the first base-name session while entering the others, then release simultaneous creates for two different same-basename paths. | Real Git repositories, real named tmux server, SHA-256 tool, PTYs, FIFOs, and readiness barrier | Every canonical path reaches its own path-marked session, parent prefixes are no longer than required, normalized collisions receive stable 12-or-more-character path suffixes, no existing session is renamed, and concurrent clients never enter the other path. |
| T3 | Worktree identity | Create a committed repository and a real linked worktree with `git worktree add`, then enter both through the shipped runner. | Real Git linked worktree, real named tmux server | Main and linked working trees have different recorded paths, session identities, and pane working directories. |
| T4 | Directory and explicit-name identity | Enter one normal directory first by its physical path and then by a symlink path, and compare session IDs. Create two explicit names for one repository, then request its automatic name. With raw tmux, create occupied explicit targets with no path option and with a different path option. | Real filesystem, Git, and named tmux server | Physical and symlink paths reuse one derived session ID; both explicit names for one path remain distinct; the automatic request lists both and fails without choosing; occupied unmarked and mismatched explicit targets cause errors with no reuse or state change. |
| T5 | Regression integration | Run all existing create, attach, list, completion, concurrent-create, help, version, installation, and server-isolation cases. | Isolated real tmux, Git, PTYs, and XDG paths | All prior contracts pass and no wrong-path or prefix-only reuse occurs. |

##### Verification Results

| Label | Observed At | Environment | Result | Evidence |
| --- | --- | --- | --- | --- |
| T1 | 2026-08-24 | Real Git repository, dedicated tmux server, and PTYs | Pass | Two subdirectories reused one path-marked session at the physical Git top level. |
| T2 | 2026-08-24 | Real Git repositories, SHA-256, synchronized real tmux calls, and PTYs | Pass | One-, two-, and three-parent labels, normalized collision hash extension, and two-path create recovery preserved distinct canonical paths. |
| T3 | 2026-08-24 | Real `git worktree add`, dedicated tmux server, and PTYs | Pass | Main and linked working trees used distinct markers, sessions, and pane directories. |
| T4 | 2026-08-24 | Real filesystem aliases, Git repositories, raw tmux sessions, and PTYs | Pass | Physical-path reuse, path-first lookup, ambiguity rejection, and explicit unmarked or mismatched conflicts preserved tmux state. |
| T5 | 2026-08-24 | Complete shipped suite with real tmux UDS, Git, PTYs, install paths, and cleanup supervisor | Pass | Legacy T1-T9, M3-T1 through M3-T5, and M4-T1 through M4-T5 passed; 18 milestone checks completed before the outer cleanup probe passed. |

##### Closure Evidence

- The runner resolves real Git top levels and linked worktrees, records
  canonical paths in `@tmux-runner-path`, and performs path-first reuse.
- Minimum-parent names, SHA-256 fallback extension, explicit-name conflicts,
  and two-path create races are covered by real Git, tmux, and PTY fixtures.
- The 2026-08-24 complete shipped suite passed legacy T1-T9, M3-T1 through
  M3-T5, and M4-T1 through M4-T5 with 18 milestone checks.
- The 2026-08-24 third-person review accepted the code after its follow-up
  confirmed the canonical verification update.
- The 2026-08-24 second-person review and follow-up accepted M4 after aligning
  collision and path-reuse help, command-specific requirements, and this
  review-state record.
- Carrying commit: `8caaea1`.

#### M5 - Discover configured repositories and select one

Origin: a158012 / M5
Identity History: none
GitHub Issue: none
Status: Complete

##### Summary

Add a repository selector without changing the meaning of the existing
session selector. Discover real Git working trees below configured roots,
present a stable numbered list, and create or reuse the selected session.

##### Scope

- Add the `repo` command and its top-level help and Bash completion entry.
- Parse the `repos` file as literal absolute paths, one per line, without
  executing shell syntax or expanding `~`, variables, globs, or substitutions.
- Ignore blank lines and full-line comments; preserve spaces in paths;
  canonicalize and deduplicate roots; warn and continue for missing roots.
- Recursively discover real Git working trees and linked worktrees, including
  a configured root that is itself a working tree.
- Exclude bare repositories and ordinary directories from repository results;
  keep ordinary directories available through `create`.
- Deduplicate canonical repository paths reached through overlapping roots or
  symbolic-link aliases, avoid symbolic-link loops, and sort results stably.
- Display minimum-parent labels where repository basenames collide and keep
  the complete selected path visible.
- Treat the canonical configured catalog as authoritative for duplicate
  display and new session names. Once the catalog exists, automatically named
  `create` calls for catalogued paths use the same collision labels; an older
  exact path-marked session is still reused without renaming.
- Apply the same SHA-256 suffix rule to catalog labels that remain equal after
  parent components are normalized.
- Revalidate the selected path immediately before creating or reusing its
  path-marked session.
- Reuse the existing real PTY selection, exact attachment, and concurrent
  creation paths.

Out of scope: Combining repositories and sessions in `ls`, evaluating the
configuration as shell code, fzf integration, remote clone or fetch, and
including bare repositories or arbitrary directories in `repo`.

##### Completion Criteria

- `tmux-runner ls` still lists only dedicated-server sessions, while
  `tmux-runner repo` lists only discovered Git working trees.
- A missing or empty `repos` file exits nonzero, prints its expected path and
  setup form, and makes no tmux change. An unreadable subtree warns and is
  skipped while readable configured roots continue.
- Literal configuration parsing handles spaces and comment lines without
  executing or expanding shell text; duplicate and missing roots are handled
  as defined by D17.
- Nested repositories and linked worktrees are found once, bare repositories
  and ordinary directories are excluded, symbolic-link aliases do not create
  duplicates, and ordering is stable across runs.
- Duplicate labels and new derived session names are stable for the same
  configured catalog regardless of repository selection order.
- A repository selection with multiple active sessions carrying its canonical
  path reports the exact names and exits without choosing one.
- Selecting a repository with no session creates and enters it; selecting it
  again reuses the same path-marked session; two concurrent selectors reach
  one session.
- Invalid input, an empty result, and a repository removed after listing exit
  nonzero without creating or attaching to a session.
- Help, completion, README, installation, and all M1-M4 behavior pass through
  the shipped files.

##### Dependencies And Decisions

- M4, D15, and D17.

##### Implementation Plan

Plan Status: accepted
Plan Acceptance: 2026-08-23 - accepted a separate `repo` command, literal
root configuration, and numbered create-or-attach selection.
Implementation Authorization: 2026-08-24 - full M5 implementation authorized
Superseded Plan Artifacts: none

1. Add a literal line parser for configured roots with canonicalization,
   deduplication, explicit missing or empty file guidance, and nonfatal
   missing or unreadable root reporting.
2. Add real Git working-tree discovery with linked-worktree, nested-repository,
   stable-order, alias-deduplication, and loop boundaries.
3. Add catalog-authoritative collision labels and the shared normalized-name
   suffix for display and automatically named create paths while leaving
   existing path-marked sessions and `ls` unchanged.
4. Connect the selection to canonical-path reuse or concurrent-safe creation,
   with a final path and working-tree recheck before any tmux change.
5. Extend help, completion, README, and real integration fixtures, then run the
   complete shipped suite and the stage review cycle.

##### Test Plan

| Label | Layer | Method | Environment | Expected Result |
| --- | --- | --- | --- | --- |
| T1 | Configuration | Exercise missing and empty `repos` files, then build a literal file with blank lines, comments, paths containing spaces, duplicate, missing, and unreadable roots, and text containing shell expansion characters. | Temporary XDG configuration and filesystem sentinels | Missing or empty files fail with the exact setup path and no tmux change; valid roots retain literal paths; bad roots warn and are skipped; duplicates collapse; and no shell text executes or expands. |
| T2 | Discovery | Create real working trees, linked worktrees, nested repositories, a bare repository, an ordinary directory, overlapping roots, symbolic-link aliases, a loop, and duplicate paths whose parent labels normalize equally; list repeatedly under a timeout and choose duplicates in opposite orders in fresh servers. | Real Git, SHA-256 tool, and temporary filesystem with bounded commands | Each working tree appears once in stable order with an unambiguous complete path; excluded entries remain absent; timeout is not reached; normalized collisions use stable suffixes; and catalog labels and new session names do not depend on selection order. |
| T3 | Selection integration | Select a repository with no session, select it again, and release two real PTY selectors for the same repository simultaneously. | Real named tmux server, PTYs, FIFOs, readiness barrier | The first selection creates and enters the path-marked session, later selections reuse its identity, and both concurrent clients reach one session. |
| T4 | Failure integration | Exercise nonnumeric and out-of-range input, no discovered repositories, a path removed after display, and a path changed from working tree to non-repository before selection. | Real filesystem, Git, tmux state monitor, bounded timeouts | Every failure exits nonzero with useful output and no session, pane, or client state change. |
| T5 | Interface regression | Verify `ls`, `repo`, help, completion, installation, identity, and server isolation through the shipped files. | Isolated real tmux, Git, PTYs, and XDG paths | `ls` remains session-only, `repo` is fully discoverable, and all earlier contracts pass. |

##### Verification Results

| Label | Observed At | Environment | Result | Evidence |
| --- | --- | --- | --- | --- |
| T1 | 2026-08-24 | Real Bash, XDG paths, filesystem, and dedicated tmux server | Pass | Literal paths, spaces, comments, duplicate, missing, unreadable, and shell-like roots were exercised; failures preserved tmux state. |
| T2 | 2026-08-24 | Real Git repositories and linked worktrees under bounded PTYs | Pass | Root, nested, linked, bare, ordinary, overlapping, symbolic-link, loop, unreadable-child, and normalized-collision cases produced stable deduplicated rows. |
| T3 | 2026-08-24 | Real named tmux servers, PTYs, FIFOs, and readiness barriers | Pass | Catalogued create, reuse, concurrent selection, legacy path reuse, and opposite selection orders on fresh servers preserved canonical identities. |
| T4 | 2026-08-24 | Real filesystem mutation, Git, tmux state monitor, and bounded PTYs | Pass | Invalid, empty, removed, changed, and ambiguous selections failed without an unintended destination. |
| T5 | 2026-08-24 | Source and installed shipped files | Pass | Help, completion, installation, documentation, server isolation, and M1-M4 regression checks passed. |

##### Closure Evidence

- `bash tests/test-tmux-runner.bash`: 23 milestone checks and the outer
  supervisor check passed through the shipped runner.
- `bash -n`, ShellCheck, and `git diff --check` passed for all changed shell
  and documentation paths.
- The third-person review accepted the implementation after the full shipped
  suite and static checks passed.
- The second-person review accepted the setup and use path after the README
  example was tied to an existing Git working tree.

#### M6 - Add recent and previous-session navigation

Origin: a158012 / M6
Identity History: none
GitHub Issue: none
Status: In progress

##### Summary

Record successful runner destinations so a user can choose a recent location
or return to the previous distinct runner session. Keep this local state safe
under concurrent commands and harmless when paths or sessions disappear.

##### Scope

- Add `recent` for a numbered most-recently-used destination list and `last`
  for the immediately previous distinct runner session.
- Add only path-marked destinations to `recent`. Track every successfully
  entered runner session by exact name for `last`, including an unmarked
  session entered by direct attach or `ls` selection.
- Keep state below `${XDG_STATE_HOME:-$HOME/.local/state}/tmux-runner` without
  sourcing or executing its contents.
- Deduplicate recent destinations while preserving most-recent-first order and
  exactly the newest 20 canonical paths.
- Make repeated `last` use alternate between the two most recently entered
  distinct sessions.
- Create the state directory with mode `0700` and records with mode `0600`.
  Serialize concurrent updates with a kernel-released file lock and bounded
  wait, then replace complete state records atomically.
- Skip stale paths, missing sessions, malformed lines, and incompatible state
  safely; do not turn state data into tmux or shell syntax.
- After `switch-client` returns 0, commit its state update. For blocking
  outside attachment, stage a transaction immediately before handoff and emit
  a unique acknowledgment from the same tmux command queue after the client is
  attached. Commit when the acknowledgment is observed, even if the attached
  client later exits nonzero; roll back only when the command exits before the
  acknowledgment and do not overwrite a later concurrent update.
- Store enough pending transaction data to reconcile after runner process
  death. On the next state access, commit an acknowledged orphan or roll back
  an unacknowledged orphan before applying a new update.
- If the state lock cannot be acquired within five seconds, exit before a tmux
  connection or state change.
- Extend help, completion, README state flow, and real concurrency fixtures.

Out of scope: Cross-host synchronization, cloud history, restoring killed
sessions, unlimited history, and recording commands executed inside tmux.

##### Completion Criteria

- `recent` displays valid destinations in most-recent-first order without
  duplicate canonical paths, retains exactly the newest 20 entries, and
  creates or reuses the selected session.
- After entering distinct sessions A and B, `last` reaches A; another `last`
  reaches B, and repeated use continues to alternate without creating a new
  session.
- Invalid commands, invalid selections, missing targets, and failed entry do
  not change either recent or previous-session state.
- Stale or malformed records are skipped with no shell evaluation and do not
  prevent valid records from working.
- Concurrent successful updates leave a complete parseable state and retain
  every successful destination when there are at most 20 distinct paths; with
  more entries, they retain exactly the newest 20.
- State paths and modes are correct, lock timeout fails before connection, and
  a failed outside attach rolls back only its own unacknowledged transaction.
- State is committed as soon as outside client attachment is acknowledged,
  remains committed after later abnormal client exit, and recovers an orphan
  pending transaction according to its recorded acknowledgment.
- Help, completion, README, installation, and all M1-M5 behavior continue to
  pass through real tmux, Git, PTY, and filesystem paths.

##### Dependencies And Decisions

- M5 and D18.

##### Implementation Plan

Plan Status: accepted
Plan Acceptance: 2026-08-23 - accepted recent selection, previous-session
navigation, XDG state placement, and success-only atomic updates.
Implementation Authorization: 2026-08-24 - full M6 implementation authorized
Superseded Plan Artifacts: none

1. Define literal, versioned state records below a mode `0700` XDG state
   directory, mode `0600` files, and safe parsing for 20 recent paths and the
   previous-session pair.
2. Add bounded kernel-released locking and atomic replacement. Commit after a
   successful switch; for blocking outside attachment, add a unique
   server-side attach acknowledgment, transaction-aware staging, and
   acknowledgment-based commit or rollback.
3. Reconcile acknowledged and unacknowledged orphan transactions before each
   state read or update.
4. Add `recent` selection with stale-entry filtering and existing path-based
   create-or-reuse behavior.
5. Add `last` lookup and alternating previous/current state transitions without
   widening its target beyond runner-managed sessions.
6. Extend help, completion, README, and concurrent real-path tests, then run
   the complete shipped suite and the stage review cycle.

##### Test Plan

| Label | Layer | Method | Environment | Expected Result |
| --- | --- | --- | --- | --- |
| T1 | Recent navigation | Enter path-marked destinations through `create`, `repo`, and `recent`, and enter marked and unmarked sessions through direct `attach` and `ls`; add more than 20 paths and repeat one. | Real Git, filesystem, named tmux server, temporary XDG state | `recent` contains only the newest 20 unique path-marked destinations in MRU order; direct and list entry still update `last`; every valid recent selection reuses or creates the correct session. |
| T2 | Previous-session navigation | Enter distinct sessions A and B, invoke `last` repeatedly inside and outside the dedicated server, and observe client targets. | Real tmux clients and PTYs | Each call reaches the previous distinct session and repeated calls alternate A and B without creating sessions. |
| T3 | Failure, acknowledgment, and stale state | Exercise invalid input, lock timeout, deleted paths and sessions, malformed and future-version records, and shell syntax text. For outside attach, test exit before acknowledgment, acknowledged attach followed by server loss and nonzero exit, runner death in the staging window, and runner death after acknowledgment. Interleave another process's successful update before rollback and reconcile each orphan on a later invocation. | Temporary XDG state, filesystem sentinels, real tmux, PTYs, readiness barriers, acknowledgment observer, and state monitor | Invalid and stale cases are safe; only an unacknowledged transaction rolls back; acknowledged entry remains committed after abnormal exit; orphan recovery follows recorded acknowledgment; later successful updates survive rollback; no stored text executes; and lock timeout leaves tmux identity and prior state unchanged. |
| T4 | Concurrent state | Release a known set of at most 20 distinct successful destinations against shared state while concurrent readers validate records; repeat with more than 20 ordered destinations. | Real tmux, Git, PTYs, readiness barrier, concurrent readers | No partial record or lost update occurs; the first final set and count equal all successful destinations, and the overflow case equals exactly the newest 20. Directory and file modes remain `0700` and `0600`. |
| T5 | Regression integration | Run all commands, help, completion, installation, repository discovery, identity, and server isolation under the outer cleanup supervisor. | Isolated real tmux, Git, PTYs, and XDG paths | All earlier contracts pass; passing runs leave no state lock, temporary file, socket, process, or workspace; failing runs preserve only the reported diagnostic workspace. |

##### Verification Results

| Label | Observed At | Environment | Result | Evidence |
| --- | --- | --- | --- | --- |
| T1 | 2026-08-24 | Real Git, filesystem, dedicated tmux servers, PTYs, and temporary XDG state | Pass | `create`, `repo`, `recent`, direct `attach`, and `ls` produced a 20-entry canonical-path MRU containing only path-marked destinations. |
| T2 | 2026-08-24 | Real named tmux servers, outside PTYs, and inside clients | Pass | Repeated `last` navigation alternated between the two previous distinct runner sessions without creating a session. |
| T3 | 2026-08-24 | Real tmux, PTYs, filesystem locks, process termination, and temporary XDG state | Pass | Invalid and stale state, five-second lock failure, rollback isolation, acknowledged server loss, and acknowledged or unacknowledged orphan recovery preserved the defined outcome. |
| T4 | 2026-08-24 | Real tmux, PTYs, concurrent readers and writers, and controlled outer-boundary ordering | Pass | Concurrent updates remained parseable and lossless, overflow retained the newest 20, and three same-sequence acknowledgment attempts received distinct committed sequences without transaction debris. |
| T5 | 2026-08-24 | Source and installed shipped files under the outer cleanup supervisor | Pass | Help, completion, installation, documentation, M1-M5 regression, successful cleanup, and forced-failure cleanup behavior passed. |

##### Closure Evidence

- `bash tests/test-tmux-runner.bash`: 28 milestone checks and the outer
  supervisor cleanup check passed through the shipped runner, real tmux,
  Git, PTYs, filesystem, and temporary XDG paths.
- `bash -n`, ShellCheck, and `git diff --check` passed for all changed shell,
  test, and documentation paths.
- The third-person review reproduced the three-client same-sequence
  acknowledgment race and accepted the retained-ticket correction after the
  full shipped suite passed with no transaction debris.
- The M7 register update records the M6 second-person acceptance and carrying
  commit.

#### M7 - Complete integrated verification and release preparation

Origin: a158012 / M7
Identity History: none
GitHub Issue: none
Status: Not started

##### Summary

Verify the complete local product as one installed system and prepare a clear
release boundary without creating a tag or GitHub release. Align installation,
help, completion, README, version identity, and cleanup with the final command
and data-flow contracts.

##### Scope

- Reverify installation of the runner, Bash completion, and the M3 no-op
  `tmux.conf`, including the existing-config preservation contract.
- Audit top-level and command help plus Bash completion for every command,
  alias, option, session target, repository path, and selection mode.
- Document the dedicated server, UDS path selection, configuration start time,
  repository identity, discovery, recent state, previous-session behavior,
  installation, first use, and complete data flow.
- Document that existing default-server sessions are neither migrated nor
  visible to runner commands and give the detach instruction for cross-server
  client use.
- Run the full shipped suite through source and installed copies with real
  tmux servers, PTYs, Git repositories and worktrees, XDG paths, concurrent
  operations, and controlled cleanup.
- Confirm that version `0.1.0` and its live or injected Git metadata remain
  consistent across the source and installed artifacts.
- Record final stage review evidence and the exact release-ready repository
  state in this canonical document.

Out of scope: Creating or pushing a Git tag, creating a GitHub release,
closing a remote milestone, system-wide installation, and adding fzf or
another selection dependency.

##### Completion Criteria

- Installation into an empty spaced home writes the complete expected file
  set with correct modes and metadata; a second install preserves an existing
  local `tmux.conf` byte for byte.
- Every documented command, option, config path, state path, migration note,
  and first-use step matches the shipped source and installed behavior.
- Source and installed version output retain the M2 identity contract and the
  final version value remains `0.1.0`.
- The complete suite passes through the real shipped runner and fixtures with
  no internal-function mock replacing the path under test.
- Test cleanup leaves no runner or default test server, socket, PTY process,
  temporary workspace, state lock, or incomplete state record.
- First-person, third-person, and second-person stage reviews have no accepted
  finding left unresolved, and the canonical row carries final evidence.

##### Dependencies And Decisions

- M3, M4, M5, M6, and D17.

##### Implementation Plan

Plan Status: accepted
Plan Acceptance: 2026-08-23 - accepted final installation, documentation,
integrated verification, and release-preparation scope.
Implementation Authorization: 2026-08-24 - full M7 implementation authorized
Superseded Plan Artifacts: none

1. Reverify non-overwriting local installation of every shipped artifact and
   compare source-to-installed content and modes.
2. Reconcile help, Bash completion, and README with the final CLI,
   configuration, state, migration, and data-flow behavior.
3. Run M7 / T1 through M7 / T4 through the source and installed paths with
   real tmux, PTY, Git, filesystem, concurrency, version, and cleanup checks
   under an outer supervisor.
4. Inspect cleanup and repository state, complete the first-person,
   third-person, and second-person stage reviews, and commit the reviewed M7
   artifacts and review evidence.
5. Run M7 / T5 against that clean committed candidate, then record its result,
   the carrying commit, and final closure in the closing canonical update;
   leave tag and GitHub release execution for separate authorization.

##### Test Plan

| Label | Layer | Method | Environment | Expected Result |
| --- | --- | --- | --- | --- |
| T1 | Installation | Install into an empty spaced home, inventory all artifacts and modes, compare the installed config with `config/tmux.conf`, modify the installed config, then install again. | GNU Make, temporary spaced `HOME`, XDG paths | The runner is mode `0755`; completion and config are mode `0644`; the first config copy matches the valid no-op source byte for byte; generated runner metadata is valid; and the modified local config is not overwritten. |
| T2 | Interface and documentation | Execute every help and version form, load completion for each command context, and follow README preparation, installation, first-use, detach, selection, recent, last, and migration instructions. | Source and installed copies in fresh temporary homes | All output and completion sets match the CLI, and every documented command and path produces the stated result. |
| T3 | Full integration | Run the complete shipped suite across dedicated and default servers, repository identity and discovery, recent state, concurrent creation and updates, and source and installed version fixtures. | Real tmux, Git, linked worktrees, PTYs, FIFOs, XDG paths, bounded timeouts | Every milestone contract passes through the real shipped path with no substitute for internal behavior. |
| T4 | Isolation and cleanup | Have an outer supervisor observe the child suite's server, client, pane, socket, process, workspace, lock, and state-file manifest before, during, and after exit. | Linux process and filesystem inspection plus real tmux queries | Default-server data remains isolated; a passing run removes or terminates every test-owned resource; a forced failing run terminates processes and preserves and reports its diagnostic workspace. |
| T5 | Release preparation | Compare the canonical plan, installed inventory, version output, `git status --porcelain`, staged and unstaged diffs, and final stage review evidence without executing a remote mutation. | Clean repository candidate and local installed copy | Version `0.1.0`, documentation, tests, and recorded evidence agree; the candidate has no staged, unstaged, or untracked change; and this workflow has executed no tag or GitHub release mutation. |

##### Verification Results

| Label | Observed At | Environment | Result | Evidence |
| --- | --- | --- | --- | --- |
| T1 | Pending | Pending | Pending | Implementation has not started. |
| T2 | Pending | Pending | Pending | Implementation has not started. |
| T3 | Pending | Pending | Pending | Implementation has not started. |
| T4 | Pending | Pending | Pending | Implementation has not started. |
| T5 | Pending | Pending | Pending | Implementation has not started. |

##### Closure Evidence

- None; implementation has not started.

## Backlog

### Work

| Group | ID | Work unit | Type | Status | Ready | Deps | Done when / Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |

### Backlog Details

None.
