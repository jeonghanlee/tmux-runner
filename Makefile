.DEFAULT_GOAL := install

RUNNER_SOURCE := bin/tmux-runner
COMPLETION_SOURCE := bin/tmux-runner-completion.bash
VERSION_INJECTOR := configure/inject-runner-version.bash
RUNNER_DIRECTORY := $(HOME)/.local/bin
COMPLETION_DIRECTORY := $(HOME)/.local/share/bash-completion/completions
RUNNER_DESTINATION := $(RUNNER_DIRECTORY)/tmux-runner
COMPLETION_DESTINATION := $(COMPLETION_DIRECTORY)/tmux-runner

ifndef VERBOSE
QUIET := @
endif

.PHONY: install
install:
	$(QUIET)install -d "$(RUNNER_DIRECTORY)"
	$(QUIET)install -m 0755 "$(RUNNER_SOURCE)" "$(RUNNER_DESTINATION)"
	$(QUIET)bash "$(VERSION_INJECTOR)" "$(RUNNER_DESTINATION)" "$(CURDIR)"
	$(QUIET)install -d "$(COMPLETION_DIRECTORY)"
	$(QUIET)install -m 0644 "$(COMPLETION_SOURCE)" "$(COMPLETION_DESTINATION)"
	$(QUIET)printf 'Installed %s and %s\n' \
		"$(RUNNER_DESTINATION)" "$(COMPLETION_DESTINATION)"
