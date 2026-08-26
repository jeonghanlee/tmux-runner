# tmux-runner

`tmux-runner` is a local Bash front end for repository-oriented tmux
sessions. It creates, lists, and enters sessions on a dedicated tmux server.

## Quick Start

The shortest supported path requires Bash 4 or later, tmux, Git, and GNU Make.
See [Requirements](#requirements) for the complete command list.

From the repository root, install the runner for the current user, make it
available in the current Bash session, and load completion:

```bash
make install
export PATH="$HOME/.local/bin:$PATH"
source "$HOME/.local/share/bash-completion/completions/tmux-runner"
```

Create or reuse a session for a repository and enter it immediately:

```bash
tmux-runner create -c /path/to/repository
```

With the starter configuration, detach by pressing `Ctrl-b`, releasing the
keys, and then pressing `d`. List the dedicated runner sessions and select one
to enter again:

```bash
tmux-runner ls
```

The commands above configure only the current shell. See
[Installation](#installation) to make `PATH` and Bash completion available in
future shells.

## Architecture

Every tmux operation uses `tmux -L tmux-runner`. The resulting Unix domain
socket is `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/tmux-runner`; the runner does not
inspect or enumerate socket files. Existing default-server sessions are not
migrated and are not visible to runner `ls`, `attach`, or Bash completion.
The runner does not move or change them.
`TMUX_TMPDIR` selects the socket root when it is set.

On the first command that starts the dedicated server, tmux reads
`${XDG_CONFIG_HOME:-$HOME/.config}/tmux-runner/tmux.conf`. If that file is
absent, the runner supplies `/dev/null`, excluding system and general user
tmux configuration. Changes to the local file take effect the next time the
dedicated server starts.

The name-based interface resolves each selected exact session name once to
tmux `#{session_id}`. If that ID has no local path marker, the runner first
stores the reserved value `tmux-runner-unmarked` with `set-option -oq` and
reads the marker again. Concurrent normalization is therefore idempotent, and
the reserved value continues to mean that the session has no canonical path.
The runner then retains the selected name, transient ID, and raw marker value
in process memory. Only the transient ID is used as the remaining tmux target.
The selected name continues to use the existing pending and main navigation
fields; the transient ID and raw marker are not written to any state record.
A session command started inside another tmux server exits with an instruction
to detach and rerun it from the outer shell before it queries or starts the
dedicated server.

Immediately before client entry, the runner creates a session-local user hook
named from the pending transaction ID, runs it once with `set-hook -R`, and
removes it. Targeting the selected session ID for all three operations keeps
the hook lookup on the identity already resolved by the runner. The hook
removes its own stored definition first, then sets the global
`@tmux-runner-path` value to the invalid reserved value
`tmux-runner-global-unset` and runs a non-shell `if-shell -F` guard targeted at
the selected ID. tmux executes commands inserted by a hook without firing
their command after-hooks, so `after-set-option` cannot change the fallback
between that assignment and the guard. Every valid local marker differs from
the fallback; removing a local marker therefore inherits the invalid value and
fails the guard. The guard also requires the ID's current exact name and raw
local marker value to match their snapshots. Its true branch queues
`attach-session` outside tmux or `switch-client` inside the dedicated server,
followed immediately by the acknowledgment command. A false guard or missing
acknowledgment makes the runner fail without updating navigation state.

For `create`, the runner resolves the requested directory to a physical path.
Inside Git, real Git metadata supplies the working-tree top level; a linked
worktree therefore remains distinct from its main working tree. Outside Git,
the physical directory itself is the identity. Each managed session stores
that canonical path in the tmux session option `@tmux-runner-path`.

Repository discovery reads
`${XDG_CONFIG_HOME:-$HOME/.config}/tmux-runner/repos`, finds candidate `.git`
directories and files without following directory symlinks, and asks real Git
to validate each physical working-tree top level. Canonical results are
deduplicated and sorted before labels or selection numbers are assigned.

Successful session entry updates local navigation state below
`${XDG_STATE_HOME:-$HOME/.local/state}/tmux-runner`. Path-marked sessions
contribute canonical paths to a 20-entry most-recently-used list. Every
entered runner session, including an unmarked session selected by `ls` or
direct attachment, contributes its exact name to the previous-session pair.
State updates use a five-second directory lock, complete-file replacement,
and an attach acknowledgment queued by tmux after outside-client handoff.

## Requirements

Session commands require Bash 4 or later, tmux, `flock`, `mktemp`, `mkdir`,
`chmod`, `mv`, `ln`, `rm`, and `sleep`. `create`, `repo`, and `recent` require
Git to validate working-tree identity. Their automatic session names also
require `hostname`; `sha256sum` is required when parent components cannot
produce an available distinct name, including normalized path collisions.
`repo`, catalog-aware automatic `create`, and catalog-aware `recent` also
require `find` and `sort`. `ls` and `attach` do not require Git, `hostname`,
`sha256sum`, `find`, or `sort`; when Git is available, entry into a marked
session uses it to classify that path before updating `recent`. A present
session marker must be the reserved `tmux-runner-unmarked` value, a legacy
absolute path, or a valid `v1:` value; other values are rejected before entry.

Installation additionally requires GNU Make, `install`, `date`, and `sed` to
copy the runner and stamp its Git and installation metadata. Confirm that the
commands are available, then verify the Bash and Make versions before
installation:

```bash
command -v bash
command -v tmux
command -v flock
command -v mktemp
command -v mkdir
command -v chmod
command -v mv
command -v ln
command -v rm
command -v sleep
command -v hostname
command -v sha256sum
command -v find
command -v sort
command -v make
command -v install
command -v git
command -v date
command -v sed
bash --version
make --version
```

## Commands

| Command | Purpose |
| --- | --- |
| `create`, `c` | Create or reuse a session and enter it immediately. |
| `repo` | Discover configured repositories, select one, and enter it. |
| `recent` | Select and enter a valid recent path-marked destination. |
| `last` | Enter the previous distinct runner session. |
| `ls` | List sessions, select one by number, and enter it. |
| `attach`, `a` | Enter an existing session by exact name. |

Create a session and enter it immediately:

```text
tmux-runner create [-s <session-name>] [-c <folder>]
tmux-runner c [-s <session-name>] [-c <folder>]
```

When `-c` is absent, the current directory is used. A path inside a Git working
tree starts the session at that working tree's top level. A non-Git path starts
it at the resolved physical directory.

Without `-s`, the runner first reuses a single session whose
`@tmux-runner-path` exactly matches the canonical path. Otherwise, the initial
name is `<repo-or-folder>-<short-hostname>`. A same-basename collision adds the
minimum distinguishing parent components. If distinct paths still normalize
to the same name, the runner adds a deterministic canonical-path SHA-256
prefix, beginning with 12 hexadecimal characters and extending it only when
that candidate is occupied by another path.

With `-s`, the supplied name controls the operation. Multiple explicit names
may refer to one canonical path. An occupied explicit name is reused only when
its stored path matches; an unmarked or differently marked name produces an
error. An automatic request that finds multiple sessions for one path also
fails and prints their exact names for direct attachment.

Discover configured repositories, choose one by number, and create or reuse
its session:

```text
tmux-runner repo
```

List complete `tmux ls` rows, choose one by number, and enter it:

```text
tmux-runner ls
```

Enter a named session directly:

```text
tmux-runner attach -t <session-name>
tmux-runner attach <session-name>
tmux-runner attach -- <session-name>
tmux-runner a -t <session-name>
tmux-runner a <session-name>
tmux-runner a -- <session-name>
```

Use `--` before a positional session name that begins with `-`.

Every supplied or derived session name replaces `.` and `:` with `_`.
Name resolution and existence checks use tmux's exact-match `=` prefix, so a
shorter name does not select a longer session with the same prefix. Final
attachment and switching use the resolved transient session ID.

## Repository Catalog

The repository catalog file contains one literal absolute search root per
line:

```text
/home/user/gitsrc
/srv/project repositories
```

Blank lines and full-line comments are ignored. Paths are not evaluated as
shell syntax: `~`, variables, globs, and command substitutions remain literal.
Configured roots are resolved to physical paths and deduplicated. Missing,
relative, or inaccessible roots produce warnings and do not stop discovery in
the remaining roots. A missing file or a file without usable roots makes
`repo` exit with the expected config path and setup form.

Discovery includes a configured root that is itself a Git working tree,
nested working trees, and linked worktrees. Bare repositories and ordinary
directories are excluded. A repository path containing a newline is also
excluded with an encoded warning because each numbered catalog entry occupies
one terminal line. Overlapping roots and symbolic-link aliases do not duplicate
results, and directory symlinks are not followed. `repo` prints each stable
label together with the complete canonical path, then always waits for a
number, even when there is one result.

When repository basenames collide, catalog labels add the minimum parent
components required to distinguish the complete catalog. Labels that still
match after `.` and `:` normalization add a deterministic canonical-path
SHA-256 prefix. The catalog therefore gives the same new session name
regardless of selection order. Automatic `create` uses the same label for a
catalogued path, while any existing exact path-marked session is reused under
its current name. The selected path and real Git top level are checked again
immediately before client or session entry.

`tmux-runner ls` remains a selector for current sessions only; it does not show
repository catalog entries.

## Local Navigation State

List valid recent destinations, choose one by number, and create or reuse its
path-matched session:

```text
tmux-runner recent
```

Enter the previous distinct runner session:

```text
tmux-runner last
```

After sessions A and B have been entered, `last` enters A. The successful
entry makes A current and B previous, so the next `last` enters B. Repeated
calls therefore alternate between the two most recently entered distinct
sessions without creating a session. If the previous session no longer
exists, `last` reports its exact name and leaves navigation state unchanged.
Session history is keyed by the full dedicated-server socket path derived from
`TMUX_TMPDIR`; `last` never uses history recorded for another runner server.

`recent` records only sessions whose marker carries a canonical path. Direct
attachment and `ls` selection of a semantically unmarked session still update
`last` but do not add a path to `recent`; its reserved marker has no path. The
state keeps exactly the newest 20 distinct canonical paths in
most-recent-first order. Missing paths and paths whose
physical identity changed are skipped. Each entry also retains whether the
path was a Git working-tree root or a plain directory; a path whose kind has
changed is skipped. A selected path is checked again immediately before client
or session entry.

The state directory is
`${XDG_STATE_HOME:-$HOME/.local/state}/tmux-runner`, mode `0700`. The main
`state` record and transaction records use mode `0600`. Fields are literal,
versioned text; percent, carriage return, tab, and newline bytes are encoded
as `%25`, `%0D`, `%09`, and `%0A`. State is parsed as data and is never
sourced or evaluated by a shell.

State version 2 stores the server socket identity with each session entry and
the `git` or `plain` kind with each recent entry. When version 1 state is read,
its unscoped session entries are excluded. Accessible recent paths are assigned
their current kind when Git is available; inaccessible paths and paths that
cannot be classified without Git are excluded. The next successful state
update writes the retained paths in version 2 format. Recent paths remain
shared across runner server identities.

The main state record requires exactly one supported version row, then accepts
valid known rows independently. Malformed and unknown rows are ignored and are
removed by the next successful canonical rewrite. Transaction `pending` and
`ack` records are strict: every required row must appear exactly once, no
unknown row or raw tab field is accepted, and a rejected transaction is never
applied to the main state.

Updates lock the state directory inode for at most five seconds and replace
the complete main record atomically. The runner stages one pending event before
the final server-side identity guard. Its transaction ID also names the
temporary session-local hook that contains the global invalid fallback, guard,
client entry, and non-background `run-shell` acknowledgment. The hook removes
its definition before those commands run, and the outer command queue also
removes it after `set-hook -R`. The acknowledgment receives the transient
session ID, requires its current name to match the pending name, and compares
an absent or reserved unmarked marker with an empty pending path or a decoded
path marker with the pending canonical path. The ID and raw marker are not
added to the main, pending, acknowledgment, or acknowledgment-ticket formats.

The parent commits as soon as that acknowledgment appears, even while an
outside client remains attached. A later server or client failure does not
erase an acknowledged entry. The next state access commits an acknowledged
orphan or removes only an unacknowledged orphan; it never restores an older
state snapshot over a concurrent success. An unsupported state version fails
without changing the record or contacting tmux.

Orphan recovery is part of state access and runs before a state-backed command
validates an interactive selection. An invalid selection records no new
navigation event, but the main state may still change if that access commits a
previously acknowledged orphan. Cleanup of an unacknowledged orphan does not
change the main state.

## Help

Show the complete command summary or help for one command:

```bash
tmux-runner --help
tmux-runner --version
tmux-runner create --help
tmux-runner repo --help
tmux-runner recent --help
tmux-runner last --help
tmux-runner ls --help
tmux-runner attach --help
```

`-h` is equivalent to `--help`. The `c` and `a` aliases provide the same help
as their long command names. `-V` is equivalent to `--version`. Help and
version output remain available when tmux is not in `PATH`.

## Version Tracking

The runner reports version `0.1.0`, Git commit identity, commit date, and
installation date:

```bash
tmux-runner --version
```

When the source template still contains both an `unknown` hash and an
`unreleased` installation date, the Git identity is resolved from the live
working tree. A tracked modification adds the `-dirty` suffix:

```text
tmux-runner version 0.1.0 (<hash> (live))
commit date:  <commit-date>
install date: live
```

`make install` stamps the installed copy using only the explicit source
directory passed to the version injector. Ambient `GIT_DIR` and
`GIT_WORK_TREE` do not change that identity. When the source directory has no
Git identity, installation stamps an `unknown` hash, an `unknown` commit date,
and the real UTC installation date:

```text
tmux-runner version 0.1.0 (unknown)
commit date:  unknown
install date: <installation-date>
```

An installed copy never changes to live discovery and never adopts a Git
working tree that happens to contain its installation path.

## Bash Completion

The completion file supplies commands, `-h` and `--help`, command options,
directories after `-c`, and live session names for `attach` and `a`. It also
supplies the help options for `repo`, `recent`, `last`, and `ls`. Session
lookup always uses the dedicated `tmux-runner` server.

## Installation

From the repository root, install for the current user:

```bash
make install
```

This installs these files:

```text
~/.local/bin/tmux-runner
~/.local/share/bash-completion/completions/tmux-runner
${XDG_CONFIG_HOME:-$HOME/.config}/tmux-runner/tmux.conf
```

The executable is installed with mode `0755` and the completion file with mode
`0644`. The starter config is installed with mode `0644` only when the target
does not already exist; later installs preserve the local file byte for byte.
The install does not modify shell startup files. Prepare the current Bash
session to find the installed executable, then confirm the resolved path:

```bash
export PATH="$HOME/.local/bin:$PATH"
command -v tmux-runner
```

Register the installed completion in the current Bash session:

```bash
source ~/.local/share/bash-completion/completions/tmux-runner
```

To make both settings available in future Bash sessions without depending on
system Bash completion setup, add these lines once to `~/.bashrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
if [[ -r "$HOME/.local/share/bash-completion/completions/tmux-runner" ]]; then
    source "$HOME/.local/share/bash-completion/completions/tmux-runner"
fi
```

Open a new Bash session, or reload that file in the current session, then
verify both registrations:

```bash
source ~/.bashrc
command -v tmux-runner
complete -p tmux-runner
```

Installation does not create or replace the local `repos` catalog. From an
existing Git working tree, append that repository as a search root. Repeating
the example may add the same line again, but discovery resolves and
deduplicates configured roots before presenting the catalog. Set
`repository_root` to another existing absolute directory when a broader search
root is wanted:

```bash
repository_root=$(git rev-parse --show-toplevel)
config_directory="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-runner"
mkdir -p "$config_directory"
printf '%s\n' "$repository_root" >> "$config_directory/repos"
tmux-runner repo
```

Installation does not create navigation state. The first session command
creates the state directory in the selected XDG state home; a successful
session entry creates or updates the main state record.

A different test home and its config path can be supplied with
`make HOME="/path/to/home" XDG_CONFIG_HOME="/path/to/home/.config" install`.
Inspect the same action without writing files with
`make -n HOME="/path/to/home" XDG_CONFIG_HOME="/path/to/home/.config" install`.

## Updating

After updating the source checkout, run the installer again from the repository
root:

```bash
make install
tmux-runner --version
```

Reinstallation replaces the executable and completion file. It preserves an
existing local `tmux.conf`.

## Local Configuration

Edit the runner-only configuration at
`${XDG_CONFIG_HOME:-$HOME/.config}/tmux-runner/tmux.conf`. If the dedicated
server is running, apply changes without ending its sessions:

```bash
tmux -L tmux-runner source-file "${XDG_CONFIG_HOME:-$HOME/.config}/tmux-runner/tmux.conf"
```

Some settings are meaningful only when the dedicated server starts. To apply
those settings from a fresh server, first detach every runner client and save
or finish all work in its sessions. The following command ends every session
on the dedicated runner server:

```bash
tmux -L tmux-runner kill-server
```

The next `tmux-runner create`, `repo`, `recent`, `last`, `ls`, or `attach`
command starts the dedicated server with the local configuration.

## Removal

Remove the installed executable and completion file while preserving local
configuration and navigation state:

```bash
rm -f "$HOME/.local/bin/tmux-runner"
rm -f "$HOME/.local/share/bash-completion/completions/tmux-runner"
```

Remove the completion setup block from `~/.bashrc` if it was added during
installation. Remove the `PATH` line only if it was added solely for
`tmux-runner` and no other local executable needs it. Local configuration
remains under
`${XDG_CONFIG_HOME:-$HOME/.config}/tmux-runner`, and navigation state remains
under `${XDG_STATE_HOME:-$HOME/.local/state}/tmux-runner`; remove those
directories separately only when their contents are no longer needed.

## First Use

Move anywhere inside the repository that should supply the default session
name and working directory, then create and enter the session:

```bash
cd /path/to/repository
tmux-runner create
```

The resulting session starts at the Git top level and normally uses
`<repo>-<short-hostname>`. Running the same command from another subdirectory
enters the existing path-matched session. With the shipped starter config, to
return to the original shell first, press `Ctrl-b`, release the keys, and then
press `d` to detach from tmux. If the runner config changes that binding, use
the configured detach binding instead. From a client connected to the default
or any other tmux server, use that server's configured detach binding before
running a `tmux-runner` session command from the outer shell.

After entering another runner session, use `tmux-runner last` to return to the
previous one. Use `tmux-runner recent` when the destination path remains but
its earlier tmux session has ended.

## Verification

Run the shipped integration suite from the repository root:

```bash
tests/test-tmux-runner.bash
```

An outer supervisor runs the complete suite once from the source tree and once
from a fresh installation under spaced `HOME` and XDG paths. Both passes use
isolated real tmux servers, terminal clients, Git repositories, worktrees, and
local state. The supervisor also observes dedicated and default sockets,
servers, panes, clients, processes, state files, and locks while they are live,
then verifies their cleanup after successful and forced-failure runs.
