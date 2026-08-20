# tmux-runner

`tmux-runner` is a local Bash front end for repository-oriented tmux
sessions. It creates, lists, and enters sessions through the tmux CLI while
leaving server and Unix domain socket management to tmux.

## Architecture

The runner has one executable, one Bash completion file, and one local install
target. Every session lookup uses an exact tmux target. Outside tmux, a
successful command uses `attach-session`; inside tmux, it uses
`switch-client`.

The runner does not inspect socket files. An outside command uses the server
selected by tmux, including `TMUX_TMPDIR` when it is set. An inside command
inherits the current client's `TMUX` value and therefore stays with that
client's server.

## Requirements

Running `tmux-runner` requires Bash 4 or later, tmux, and `hostname`.
Installation additionally requires GNU Make and `install`. Confirm that the
commands are available, then verify the Bash and Make versions before
installation:

```bash
command -v bash
command -v tmux
command -v hostname
command -v make
command -v install
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
tmux-runner create --help
tmux-runner ls --help
tmux-runner attach --help
```

`-h` is equivalent to `--help`. The `c` and `a` aliases provide the same help
as their long command names. Help remains available when tmux is not in
`PATH`.

## Bash Completion

The completion file supplies commands, `-h` and `--help`, command options,
directories after `-c`, and live session names for `attach` and `a`. Live
session lookup uses the same tmux server selection as the current shell.

## Installation

From the repository root, install for the current user:

```bash
make install
```

This writes only these files:

```text
~/.local/bin/tmux-runner
~/.local/share/bash-completion/completions/tmux-runner
```

The executable is installed with mode `0755` and the completion file with mode
`0644`. The install does not modify shell startup files. Prepare the current
Bash session to find the installed executable, then confirm the resolved path:

```bash
export PATH="$HOME/.local/bin:$PATH"
command -v tmux-runner
```

Register the installed completion in the current Bash session:

```bash
source ~/.local/share/bash-completion/completions/tmux-runner
```

A different test home can be supplied with
`make HOME="/path/to/home" install`; inspect the same action without writing
files with `make -n HOME="/path/to/home" install`.

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
tmux.

## Verification

Run the shipped integration suite from the repository root:

```bash
tests/test-tmux-runner.bash
```

The suite uses isolated real tmux servers and terminal clients.
