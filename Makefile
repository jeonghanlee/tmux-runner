.DEFAULT_GOAL := install

RUNNER_SOURCE := bin/tmux-runner
COMPLETION_SOURCE := bin/tmux-runner-completion.bash
RUNNER_DESTINATION := $(HOME)/.local/bin/tmux-runner
COMPLETION_DESTINATION := $(HOME)/.local/share/bash-completion/completions/tmux-runner

ifndef VERBOSE
QUIET := @
endif

.PHONY: install
install:
	$(QUIET)install -d "$(dir $(RUNNER_DESTINATION))"
	$(QUIET)install -m 0755 "$(RUNNER_SOURCE)" "$(RUNNER_DESTINATION)"
	$(QUIET)install -d "$(dir $(COMPLETION_DESTINATION))"
	$(QUIET)install -m 0644 "$(COMPLETION_SOURCE)" "$(COMPLETION_DESTINATION)"
	$(QUIET)printf 'Installed %s and %s\n' \
		"$(RUNNER_DESTINATION)" "$(COMPLETION_DESTINATION)"
