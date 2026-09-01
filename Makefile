.DEFAULT_GOAL := install

RUNNER_SOURCE := bin/tmux-runner
COMPLETION_SOURCE := bin/tmux-runner-completion.bash
CONFIG_SOURCE := config/tmux.conf
VERSION_INJECTOR := configure/inject-runner-version.bash
CONFIG_INSTALLER := configure/install-runner-config.bash
RUNNER_DIRECTORY := $(HOME)/.local/bin
COMPLETION_DIRECTORY := $(HOME)/.local/share/bash-completion/completions
CONFIG_HOME := $(if $(XDG_CONFIG_HOME),$(XDG_CONFIG_HOME),$(HOME)/.config)
CONFIG_DIRECTORY := $(CONFIG_HOME)/tmux-runner
RUNNER_DESTINATION := $(RUNNER_DIRECTORY)/tmux-runner
COMPLETION_DESTINATION := $(COMPLETION_DIRECTORY)/tmux-runner
CONFIG_DESTINATION := $(CONFIG_DIRECTORY)/tmux.conf
CONFIG_PROMPT ?= 0

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
	$(QUIET)install -d "$(CONFIG_DIRECTORY)"
	$(QUIET)bash "$(CONFIG_INSTALLER)" "$(CONFIG_SOURCE)" \
		"$(CONFIG_DESTINATION)" "$(CONFIG_PROMPT)"
	$(QUIET)printf 'Installed %s and %s\nLocal config: %s\n' \
		"$(RUNNER_DESTINATION)" "$(COMPLETION_DESTINATION)" \
		"$(CONFIG_DESTINATION)"
