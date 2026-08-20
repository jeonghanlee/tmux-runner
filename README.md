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

## Commands

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
tmux-runner a -t <session-name>
tmux-runner a <session-name>
```

Every supplied or derived session name replaces `.` and `:` with `_`.
Targets are passed to tmux with the exact-match `=` prefix, so a shorter name
does not select a longer session with the same prefix.

## Bash Completion

The completion file supplies commands, command options, directories after
`-c`, and live session names for `attach` and `a`. Live session lookup uses the
same tmux server selection as the current shell.

## Installation

From the repository root, install for the current user:

```text
make install
```

This writes only these files:

```text
~/.local/bin/tmux-runner
~/.local/share/bash-completion/completions/tmux-runner
```

The executable is installed with mode `0755` and the completion file with mode
`0644`. The install does not modify shell startup files. Ensure
`~/.local/bin` is already in `PATH` before calling `tmux-runner` by name.

Register the installed completion in the current Bash session:

```text
source ~/.local/share/bash-completion/completions/tmux-runner
```

A different test home can be supplied with
`make HOME=/path/to/home install`; inspect the same action without writing files
with `make -n HOME=/path/to/home install`.

## Verification

Run the shipped integration suite from the repository root:

```text
tests/test-tmux-runner.bash
```

The suite uses isolated real tmux servers and terminal clients.
