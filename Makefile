# Makefile — devbox helper wrapper
# Default target: help
# POSIX make syntax; all recipes are tab-indented.

MARKER := $(HOME)/docker/lib/.devbox-marker

.PHONY: help doctor test lint compose-check anchor-check \
        start stop status backup security-check rotate-ollama-auth \
        install-systemd uninstall-systemd

# ──────────────────────────────────────────────────────────────────────────────
# Default target
# ──────────────────────────────────────────────────────────────────────────────
help:
	@echo "devbox — available targets:"
	@echo "  help              Print this help message"
	@echo "  doctor            Read-only preflight: verify install, daemon, and containers"
	@echo "  test              Run lint + compose-check + anchor-check + contract bats suite"
	@echo "  lint              Shellcheck + bash -n every .sh in the repo"
	@echo "  compose-check     Validate docker compose config for all services"
	@echo "  anchor-check      Verify contract anchor consistency across compose files"
	@echo "  start             Start all services via installed start-all.sh"
	@echo "  stop              Stop all services via installed stop-all.sh"
	@echo "  status            Show service/container status via installed status.sh"
	@echo "  backup            Run installed backup.sh"
	@echo "  security-check    Run installed security-check.sh"
	@echo "  rotate-ollama-auth  Rotate Ollama auth credentials via installed helper"
	@echo "  install-systemd     Render and install devbox systemd units (requires root)"
	@echo "  uninstall-systemd   Stop, disable, and remove devbox systemd units (requires root)"

# ──────────────────────────────────────────────────────────────────────────────
# Read-only preflight doctor (runs regardless of marker)
# ──────────────────────────────────────────────────────────────────────────────
doctor:
	@FAIL=0; \
	echo "=== devbox doctor ==="; \
	\
	echo ""; \
	echo "-- docker CLI"; \
	if command -v docker >/dev/null 2>&1; then \
	    echo "  [OK] docker found: $$(docker --version)"; \
	else \
	    echo "  [FAIL] docker not installed or not in PATH" >&2; \
	    FAIL=$$((FAIL+1)); \
	fi; \
	if docker info >/dev/null 2>&1; then \
	    echo "  [OK] docker daemon reachable"; \
	else \
	    echo "  [FAIL] docker daemon not reachable (is it running?)" >&2; \
	    FAIL=$$((FAIL+1)); \
	fi; \
	\
	echo ""; \
	echo "-- tailscale CLI"; \
	if command -v tailscale >/dev/null 2>&1; then \
	    echo "  [OK] tailscale found: $$(tailscale version 2>/dev/null | head -1)"; \
	else \
	    echo "  [WARN] tailscale CLI not found (optional for local-only use)"; \
	fi; \
	\
	echo ""; \
	echo "-- config.env"; \
	CONFIG_ENV="$$HOME/.config/devbox/config.env"; \
	if [ -f "$$CONFIG_ENV" ]; then \
	    echo "  [OK] $$CONFIG_ENV exists"; \
	else \
	    echo "  [FAIL] $$CONFIG_ENV not found (run setup.sh to install)" >&2; \
	    FAIL=$$((FAIL+1)); \
	fi; \
	\
	echo ""; \
	echo "-- installed contract"; \
	CONTRACT="$$HOME/docker/lib/devbox-contract.sh"; \
	if [ -f "$$CONTRACT" ]; then \
	    echo "  [OK] $$CONTRACT exists"; \
	else \
	    echo "  [FAIL] $$CONTRACT not found (run setup.sh to install)" >&2; \
	    FAIL=$$((FAIL+1)); \
	fi; \
	\
	echo ""; \
	echo "-- install marker"; \
	MARKER_PATH="$$HOME/docker/lib/.devbox-marker"; \
	if [ -f "$$MARKER_PATH" ]; then \
	    echo "  [OK] marker found: $$MARKER_PATH"; \
	else \
	    echo "  [FAIL] marker not found: $$MARKER_PATH (run setup.sh to install)" >&2; \
	    FAIL=$$((FAIL+1)); \
	fi; \
	\
	echo ""; \
	echo "-- container status"; \
	if [ -f "$$CONTRACT" ]; then \
	    . "$$CONTRACT"; \
	    for svc in $${DEVBOX_SERVICES[*]}; do \
	        VAR="DEVBOX_CONTAINERS_$$(echo "$$svc" | tr '-' '_')"; \
	        eval "CONTAINERS=\"\$${$$VAR}\""; \
	        for ctr in $$CONTAINERS; do \
	            STATE="$$(docker inspect --format='{{.State.Status}}' "$$ctr" 2>/dev/null || echo 'not found')"; \
	            if [ "$$STATE" = "running" ]; then \
	                echo "  [OK] $$ctr: running"; \
	            else \
	                echo "  [WARN] $$ctr: $$STATE"; \
	            fi; \
	        done; \
	    done; \
	else \
	    echo "  [SKIP] contract not installed — cannot enumerate containers"; \
	fi; \
	\
	echo ""; \
	if [ "$$FAIL" -gt 0 ]; then \
	    echo "[FAIL] doctor found $$FAIL problem(s). Run 'setup.sh' to install devbox." >&2; \
	    exit 1; \
	fi; \
	echo "[OK] All preflight checks passed."

# ──────────────────────────────────────────────────────────────────────────────
# CI targets (no marker required)
# ──────────────────────────────────────────────────────────────────────────────
lint:
	@echo "Running: scripts/ci/lint.sh"
	@bash scripts/ci/lint.sh

compose-check:
	@echo "Running: scripts/ci/check-compose-config.sh"
	@bash scripts/ci/check-compose-config.sh

anchor-check:
	@echo "Running: scripts/ci/check-anchor-consistency.sh"
	@bash scripts/ci/check-anchor-consistency.sh

test: lint compose-check anchor-check
	@echo "Running: bats tests/contract/contract.bats"
	@bats tests/contract/contract.bats

# ──────────────────────────────────────────────────────────────────────────────
# Install-dependent targets (require marker)
# ──────────────────────────────────────────────────────────────────────────────
_check-marker:
	@if [ ! -f "$(MARKER)" ]; then \
	    echo "[ERROR] devbox is not installed — $(MARKER) not found." >&2; \
	    echo "        Run 'setup.sh' to install, then retry." >&2; \
	    echo "        Run 'make doctor' to diagnose the installation state." >&2; \
	    exit 1; \
	fi

start: _check-marker
	@echo "Running: $(HOME)/docker/start-all.sh"
	@$(HOME)/docker/start-all.sh

stop: _check-marker
	@echo "Running: $(HOME)/docker/stop-all.sh"
	@$(HOME)/docker/stop-all.sh

status: _check-marker
	@echo "Running: $(HOME)/docker/status.sh"
	@$(HOME)/docker/status.sh

backup: _check-marker
	@echo "Running: $(HOME)/docker/lib/backup.sh"
	@$(HOME)/docker/lib/backup.sh

security-check: _check-marker
	@echo "Running: $(HOME)/docker/lib/security-check.sh"
	@$(HOME)/docker/lib/security-check.sh

rotate-ollama-auth: _check-marker
	@echo "Running: $(HOME)/docker/lib/rotate-ollama-auth.sh"
	@$(HOME)/docker/lib/rotate-ollama-auth.sh

# ──────────────────────────────────────────────────────────────────────────────
# Systemd unit management (requires marker + root)
# ──────────────────────────────────────────────────────────────────────────────
install-systemd: _check-marker
	@echo "Running: sudo $(HOME)/docker/install-systemd.sh"
	@sudo $(HOME)/docker/install-systemd.sh

uninstall-systemd:
	@echo "Stopping and disabling devbox systemd units..."
	@sudo systemctl stop devbox-backup.timer 2>/dev/null || true
	@sudo systemctl stop devbox.service 2>/dev/null || true
	@sudo systemctl disable devbox-backup.timer 2>/dev/null || true
	@sudo systemctl disable devbox.service 2>/dev/null || true
	@sudo rm -f /etc/systemd/system/devbox.service \
	            /etc/systemd/system/devbox-backup.service \
	            /etc/systemd/system/devbox-backup.timer
	@sudo systemctl daemon-reload
	@echo "[OK] devbox systemd units removed."
