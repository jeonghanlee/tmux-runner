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

## Requirements

Running `tmux-runner` requires Bash 4 or later, tmux, and `hostname`.
Installation additionally requires GNU Make, `install`, Git, `date`, and
`sed` to copy the runner and stamp its Git and installation metadata. Confirm
that the commands are available, then verify the Bash and Make versions before
installation:

```bash
command -v bash
command -v tmux
command -v hostname
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
| `ls` | List sessions, select one by number, and enter it. |
| `attach`, `a` | Enter an existing session by exact name. |

Create a session and enter it immediately:

```text
tmux-runner create [-s <session-name>] [-c <folder>]
tmux-runner c [-s <session-name>] [-c <folder>]
```

When `-c` is absent, the current directory is used. When `-s` is absent, the
session name is `<folder>-<short-hostname>` after directory resolution. If the
exact session already exists, it is entered without creating another session.

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
Targets are passed to tmux with the exact-match `=` prefix, so a shorter name
does not select a longer session with the same prefix.

## Help

Show the complete command summary or help for one command:

```bash
tmux-runner --help
tmux-runner --version
tmux-runner create --help
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
directories after `-c`, and live session names for `attach` and `a`. Session
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

A different test home and its config path can be supplied with
`make HOME="/path/to/home" XDG_CONFIG_HOME="/path/to/home/.config" install`.
Inspect the same action without writing files with
`make -n HOME="/path/to/home" XDG_CONFIG_HOME="/path/to/home/.config" install`.

## First Use

Move to the repository that should supply the default session name and working
directory, then create and enter the session:

```bash
cd /path/to/repository
tmux-runner create
```

The resulting session name is `<folder>-<short-hostname>`. Running the same
command again enters the existing exact-name session. To return to the original
shell first, press `Ctrl-b`, release the keys, and then press `d` to detach from
tmux. Use the same detach sequence before running a `tmux-runner` session
command from a client connected to the default or any other tmux server.

## Verification

Run the shipped integration suite from the repository root:

```bash
tests/test-tmux-runner.bash
```

The suite uses isolated real tmux servers and terminal clients.
