# Work Register

## Scope

This document tracks milestone and backlog work selected for `tmux-runner` on
`master` after the 2026-08-31 reset.

**Out of scope:** Work completed at or before prior state commit
`519be6fb69b32b3b17c275ec213538764562eb13`; inspect that committed state and
Git history for its milestone plans, verification evidence, and decisions.
System-wide installation, service supervision, Git tag creation or push,
GitHub release execution, GitHub projection, and tmux window or layout
management remain out of scope unless new work explicitly changes the
boundary.

Release line: master
Milestone index: 519be6f
Canonical path: `docs/milestone-519be6f.md`
Canonical branch or ref: master
Git upstream: origin/master
Remote tracker: none

Next session entry point: no active milestone or backlog work remains. Wait for
new work to be selected.

## Milestone

### Work

| Group | ID | Work unit | Type | Status | Ready | Deps | Done when / Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| | M1 | Ship runner defaults and opt-in config replacement | Milestone | Complete | No | | Commit `2678d4d` is on `origin/master`; [detail](#m1---ship-runner-defaults-and-opt-in-config-replacement) |

Milestone tally: Complete 1; total 1.

### Decisions

| ID | Decision | Decision Date |
| --- | --- | --- |

### Milestone Details

#### M1 - Ship Runner Defaults And Opt-In Config Replacement

Origin: 519be6f / M1
Identity History: none
GitHub Issue: none
Status: Complete

##### Summary

Ship a complete runner-only tmux configuration and an explicit replacement
prompt for existing local config files.

##### Scope

Define the installed runner defaults, reload the installed config path, and
support confirmed replacement while preserving symlinks.

Out of scope: System-wide tmux configuration, forced replacement, and changes
to the general user tmux config.

##### Completion Criteria

- New installations receive the shipped runner config.
- Default reinstallation preserves existing config; confirmed replacement updates a regular file and preserves symlinks.
- Real source, installed, and live-server checks pass and the implementation commit is on `origin/master`.

##### Dependencies And Decisions

- None.

##### Implementation Plan

Plan Status: accepted
Plan Acceptance: 2026-08-31
Implementation Authorization: 2026-08-31
Superseded Plan Artifacts: none

1. Define runner-specific tmux defaults and reload the installed config path.
2. Add an opt-in replacement prompt that preserves symlinks.
3. Verify source, fresh installation, and live-server behavior.

##### Test Plan

| Label | Layer | Method | Environment | Expected Result |
| --- | --- | --- | --- | --- |
| T1 | Integration | Run `tests/test-tmux-runner.bash` through its real source and fresh-install paths | Source tree and fresh installation | Both 30-check suites and supervisor checks pass |
| T2 | Runtime | Compare the source and installed config, then query the actual named server | User installation with tmux 3.5a | Files match and the terminal, history, and reload binding values are active |

##### Verification Results

| Label | Observed At | Environment | Result | Evidence |
| --- | --- | --- | --- | --- |
| T1 | 2026-08-31 | Source tree and fresh installation | Pass | `PASS INTEGRATION-SUITE`, `PASS SUPERVISOR-CLEANUP`, and `PASS RESOURCE-OBSERVATION` |
| T2 | 2026-08-31T22:46:53-07:00 | User installation and `tmux-runner` server | Pass | Installed config matched the source; `tmux-256color`, history `100000`, and the installed-path `r` binding were active |

##### Closure Evidence

- Completion accepted on 2026-08-31 after the required checks passed.
- At 2026-08-31T22:46:53-07:00, fetched `origin/master` and local `HEAD` both resolved to `2678d4d2288774fcffb347d1e5a3979dfbfccbac`.
- Commit `2678d4d` contains the runner config, installer, integration tests, and installation documentation.
- No external gate or linked GitHub issue remains.

## Backlog

### Work

| Group | ID | Work unit | Type | Status | Ready | Deps | Done when / Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |

### Backlog Details

None.

## History

| Reset Date | Prior State Commit |
| --- | --- |
| 2026-08-31 | `519be6fb69b32b3b17c275ec213538764562eb13` |
