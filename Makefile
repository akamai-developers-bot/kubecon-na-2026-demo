PKGS := linode-cli rclone kubectl coreutils jq python3 curl xclip age
BREW_INSTALL := curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
.DEFAULT_GOAL = help

ifeq ($(shell [ -f /opt/homebrew/bin/bash ] && echo yes),yes)
	BASH_ENV := /opt/homebrew/bin/bash
else
	BASH_ENV := /home/linuxbrew/.linuxbrew/lib/bash
endif

RUN := $(BASH_ENV) ./run.sh

deps-brew:
	@command -v brew >/dev/null 2>&1 || $(BREW_INSTALL);

deps-pkgs:
	@$(foreach pkg,$(PKGS),brew install -y $(pkg);)

# default: help

# main
apps:
	@$(RUN) apps

clean:
	@$(RUN) clean

copy:
	@$(RUN) copy

create:
	@$(RUN) create

deps:
	@$(RUN) deps

destroy:
	@$(RUN) destroy

headlamp:
	@$(RUN) headlamp

help:
	@$(RUN) help

info:
	@$(RUN) info

prod:
	@$(RUN) prod

reset:
	@$(RUN) reset

setup:
	@$(RUN) setup
