# Makefile — fts-quadlet-setup
# Targets: lint, test, install, uninstall, help
#
# Requires: bats-core, shellcheck, podman >= 4.4
# Usage:
#   make test           # lint + bats
#   make install IP=x   # deploy to this host
#   make uninstall      # stop + remove unit files

SHELL      := /bin/sh
QUADLET_DIR ?= /etc/containers/systemd
IP         ?=

UNITS := \
	networks/fts.network \
	volumes/fts-data.volume \
	volumes/fts-ui-data.volume \
	containers/freetakserver.container \
	containers/freetakserver-ui.container

.PHONY: all lint test install uninstall help

all: lint test

## lint: run shellcheck against fts_setup.sh
lint:
	shellcheck -S style fts_setup.sh

## test: run lint + full bats test suite
test: lint
	bats tests/fts_setup.bats

## install: deploy quadlet units to QUADLET_DIR (requires root)
##          Set IP= for site-local IP, e.g.: make install IP=192.0.2.10
install:
	@if [ -z "$(IP)" ] && [ -z "$$FTS_IP" ]; then \
		echo "ERROR: set IP= or FTS_IP environment variable" >&2; \
		exit 1; \
	fi
	FTS_IP="$(IP)$(FTS_IP)" sh fts_setup.sh --quadlet-dir "$(QUADLET_DIR)" --ip "$(IP)$(FTS_IP)"

## uninstall: stop services and remove unit files
uninstall:
	-systemctl disable --now freetakserver.service freetakserver-ui.service
	-systemctl daemon-reload
	@for f in $(UNITS); do \
		base=$$(basename $$f); \
		echo "Removing $(QUADLET_DIR)/$$base"; \
		rm -f "$(QUADLET_DIR)/$$base"; \
	done
	@echo "fts.env preserved — remove manually if desired: $(QUADLET_DIR)/fts.env"

## help: print this message
help:
	@grep -E '^## ' Makefile | sed 's/^## //'
