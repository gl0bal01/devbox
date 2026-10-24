# devbox — operator and CI entry points. `make help` lists targets.
SHELL := /bin/bash
DEVBOX_HOME ?= $(HOME)/docker
MARKER := $(DEVBOX_HOME)/lib/.devbox-marker

.PHONY: help ci ci-fast test lint docs-check bats compose-check e2e hooks doctor \
        start stop status backup security-check rotate-ollama-auth install-systemd uninstall-systemd _installed

help:
	@echo "Development (repo)"
	@echo "  ci                 Full local mirror of CI, incl. e2e in a throwaway container (pre-push runs this)"
	@echo "  ci-fast            Same without e2e"
	@echo "  test               lint + docs-check + bats + compose-check"
	@echo "  e2e                Install devbox for real inside a disposable systemd container"
	@echo "  hooks              Use .githooks/ (pre-push runs 'make ci')"
	@echo "Operations (installed host)"
	@echo "  doctor             Install state, contract drift, container health"
	@echo "  start | stop | status | backup | security-check | rotate-ollama-auth"
	@echo "  install-systemd | uninstall-systemd   (sudo)"

ci:
	@scripts/ci/local.sh

ci-fast:
	@scripts/ci/local.sh --fast

test: lint docs-check bats compose-check

lint:
	@scripts/ci/lint.sh

docs-check:
	@scripts/ci/check-docs-tree.sh

bats:
	@bats tests/unit tests/contract

compose-check:
	@scripts/ci/check-compose-config.sh

e2e:
	@scripts/ci/e2e-container.sh

hooks:
	@git config core.hooksPath .githooks && echo "pre-push hook enabled (.githooks/pre-push)"

doctor:
	@./setup.sh --check || true
	@if [ -f "$(MARKER)" ]; then $(DEVBOX_HOME)/status.sh; else echo "Not installed: sudo ./setup.sh"; fi

_installed:
	@[ -f "$(MARKER)" ] || { echo "devbox is not installed ($(MARKER) missing): run sudo ./setup.sh" >&2; exit 1; }

start: _installed
	@$(DEVBOX_HOME)/start-all.sh
stop: _installed
	@$(DEVBOX_HOME)/stop-all.sh
status: _installed
	@$(DEVBOX_HOME)/status.sh
backup: _installed
	@$(DEVBOX_HOME)/backup.sh
security-check: _installed
	@$(DEVBOX_HOME)/security-check.sh
rotate-ollama-auth: _installed
	@$(DEVBOX_HOME)/rotate-ollama-auth.sh
install-systemd: _installed
	@sudo $(DEVBOX_HOME)/install-systemd.sh
uninstall-systemd:
	@sudo systemctl disable --now devbox-backup.timer devbox.service 2>/dev/null || true
	@sudo rm -f /etc/systemd/system/devbox.service /etc/systemd/system/devbox-backup.service /etc/systemd/system/devbox-backup.timer
	@sudo systemctl daemon-reload
	@echo "devbox systemd units removed."
