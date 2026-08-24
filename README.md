# tmux-runner

`tmux-runner` is a local Bash front end for repository-oriented tmux
sessions. It creates, lists, and enters sessions on a dedicated tmux server.

## Architecture

Every tmux operation uses `tmux -L tmux-runner`. The resulting Unix domain
socket is `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/tmux-runner`; the runner does not
inspect or enumerate socket files. Default-server sessions are separate and
are not listed, completed, moved, or changed by the runner.
`TMUX_TMPDIR` selects the socket root when it is set.

On the first command that starts the dedicated server, tmux reads
`${XDG_CONFIG_HOME:-$HOME/.config}/tmux-runner/tmux.conf`. If that file is
absent, the runner supplies `/dev/null`, excluding system and general user
tmux configuration. Changes to the local file take effect the next time the
dedicated server starts.

Every session lookup uses an exact tmux target. Outside tmux, a successful
command uses `attach-session`. Inside the dedicated server, it uses
`switch-client`. A session command started inside another tmux server exits
with an instruction to detach and rerun it from the outer shell before it
queries or starts the dedicated server.

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
`chmod`, `mv`, `ln`, `rm`, and `sleep`. `create` also requires Git
to distinguish working trees from ordinary directories. An automatic
`create` requires `hostname`; `sha256sum` is required when parent components
cannot produce an available distinct name, including normalized path
collisions. `ls` and `attach` do not use Git or `hostname`.
`repo`, and automatic `create` when a usable repository catalog is configured,
also require `find` and `sort`.

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
Attachment, switching, and existence checks use tmux's exact-match `=` prefix,
so a shorter name does not select a longer session with the same prefix.

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
directories are excluded. Overlapping roots and symbolic-link aliases do not
duplicate results, and directory symlinks are not followed. `repo` prints each
stable label together with the complete canonical path, then always waits for
a number, even when there is one result.

When repository basenames collide, catalog labels add the minimum parent
components required to distinguish the complete catalog. Labels that still
match after `.` and `:` normalization add a deterministic canonical-path
SHA-256 prefix. The catalog therefore gives the same new session name
regardless of selection order. Automatic `create` uses the same label for a
catalogued path, while any existing exact path-marked session is reused under
its current name. The selected path and real Git top level are checked again
immediately before any tmux change.

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

`recent` records only sessions carrying `@tmux-runner-path`. Direct
attachment and `ls` selection of an unmarked session still update `last` but
do not add a path to `recent`. The state keeps exactly the newest 20 distinct
canonical paths in most-recent-first order. Missing paths and paths whose
physical or Git identity changed are skipped. A selected path is checked
again immediately before any tmux change.

The state directory is
`${XDG_STATE_HOME:-$HOME/.local/state}/tmux-runner`, mode `0700`. The main
`state` record and transaction records use mode `0600`. Fields are literal,
versioned text; percent, carriage return, tab, and newline bytes are encoded
as `%25`, `%0D`, `%09`, and `%0A`. State is parsed as data and is never
sourced or evaluated by a shell.

Updates lock the state directory inode for at most five seconds and replace
the complete main record atomically. Outside tmux, the runner stages one
pending event immediately before attachment and queues a non-background
`run-shell` acknowledgment after `attach-session` in the same tmux command
queue. The parent commits as soon as that acknowledgment appears, even while
the client remains attached. A later server or client failure does not erase
an acknowledged entry. The next state access commits an acknowledged orphan
or removes only an unacknowledged orphan; it never restores an older state
snapshot over a concurrent success. An unsupported state version fails
without changing the record or contacting tmux.

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

When executed directly from the repository, the Git identity is resolved from
the live working tree. A tracked modification adds the `-dirty` suffix:

```text
tmux-runner version 0.1.0 (<hash> (live))
commit date:  <commit-date>
install date: live
```

`make install` stamps the installed copy with the source Git identity, commit
date, and installation date. The installed command therefore retains its
deployment identity when it is executed outside the repository.

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

Installation does not create or replace the local `repos` catalog. From an
existing Git working tree, create it with that repository as the first search
root. Replace `repository_root` with another existing absolute directory when
a broader catalog is wanted:

```bash
repository_root=$(git rev-parse --show-toplevel)
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/tmux-runner"
printf '%s\n' "$repository_root" > "${XDG_CONFIG_HOME:-$HOME/.config}/tmux-runner/repos"
tmux-runner repo
```

Installation does not create navigation state. The first session command
creates the state directory in the selected XDG state home; a successful
session entry creates or updates the main state record.

A different test home and its config path can be supplied with
`make HOME="/path/to/home" XDG_CONFIG_HOME="/path/to/home/.config" install`.
Inspect the same action without writing files with
`make -n HOME="/path/to/home" XDG_CONFIG_HOME="/path/to/home/.config" install`.

## First Use

Move anywhere inside the repository that should supply the default session
name and working directory, then create and enter the session:

```bash
cd /path/to/repository
tmux-runner create
```

The resulting session starts at the Git top level and normally uses
`<repo>-<short-hostname>`. Running the same command from another subdirectory
enters the existing path-matched session. To return to the original shell
first, press `Ctrl-b`, release the keys, and then press `d` to detach from tmux.
Use the same detach sequence before running a `tmux-runner` session command
from a client connected to the default or any other tmux server.

After entering another runner session, use `tmux-runner last` to return to the
previous one. Use `tmux-runner recent` when the destination path remains but
its earlier tmux session has ended.

## Verification

Run the shipped integration suite from the repository root:

```bash
tests/test-tmux-runner.bash
```

The suite uses isolated real tmux servers and terminal clients.
