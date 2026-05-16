#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# =============================================================================
# DEVBOX RUNTIME CONTRACT (v4.1 P3 post-fix)
# =============================================================================
# Single source of truth for install layout, service identities, container
# names, Traefik hosts, named volumes, backup targets, pinned support images,
# and the helper accessors that consume them. Sourced by setup.sh (repo
# copy) and by helpers in ${DEVBOX_HOME} after install (installed copy).
#
# This file MUST be POSIX-shell-source-safe (no `local`, no bashisms outside
# DEVBOX_SERVICES array). Helpers source it via `. devbox-contract.sh`.
#
# Authority: installed copy at ${DEVBOX_HOME}/lib/devbox-contract.sh is the
# runtime authority. Repo copy at scripts/lib/devbox-contract.sh is the
# source. setup.sh is the only sync path. Helpers print a non-blocking WARN
# (via devbox_contract_warn_drift) when `cmp -s` detects drift between the
# two copies.
# =============================================================================

# Contract format version. Bumped when the schema of declared variables
# changes in a backwards-incompatible way. Helpers can refuse old/new
# combinations if needed.
#
# History:
#   v1 — initial P0 contract
#   v2 — add DEVBOX_USER, devbox_contract_warn_drift(),
#        devbox_compose_chain_key(), devbox_compose_chain_for()
DEVBOX_CONTRACT_VERSION=2

# Install root (override with DEVBOX_HOME env for tests).
DEVBOX_HOME="${DEVBOX_HOME:-${HOME}/docker}"

# Operator user account that owns the install and runs the systemd units.
# setup.sh overrides this with NEW_USER at install time; install-systemd.sh
# consumes the value when rendering devbox.service / devbox-backup.service.
DEVBOX_USER="${DEVBOX_USER:-${SUDO_USER:-${USER:-dev}}}"

# Ordered service list. Helpers iterate this for start/stop/status/backup.
# Order matters: dependencies first (traefik before ollama-openwebui).
DEVBOX_SERVICES=(traefik ollama-openwebui)

# Per-service install subdirectory (relative to DEVBOX_HOME).
DEVBOX_DIR_traefik="traefik"
DEVBOX_DIR_ollama_openwebui="ollama-openwebui"

# Per-service base compose file (relative to the install subdir).
DEVBOX_COMPOSE_traefik="docker-compose.yml"
DEVBOX_COMPOSE_ollama_openwebui="docker-compose.yml"

# Per-service HTTPS overlay compose file. Helpers chain base + overlay when
# ENABLE_HTTPS=true.
DEVBOX_COMPOSE_HTTPS_traefik="docker-compose.https.yml"
DEVBOX_COMPOSE_HTTPS_ollama_openwebui="docker-compose.https.yml"

# Per-service container names (space-separated). Used by status.sh and
# security-check.sh for `docker inspect` and by tests/contract/contract.bats
# to assert names match what compose actually declares.
DEVBOX_CONTAINERS_traefik="traefik docker-socket-proxy"
DEVBOX_CONTAINERS_ollama_openwebui="ollama openwebui"

# Per-service Traefik hosts (space-separated). Every host listed here MUST
# have a matching `traefik.http.routers.*.rule=Host(...)` label in the
# corresponding compose file. Asserted by tests/contract/contract.bats.
DEVBOX_HOST_traefik="traefik.internal"
DEVBOX_HOST_ollama_openwebui="ai.internal ollama.internal"

# Per-service named volumes that must be backed up via `docker run -v <vol>`.
# Traefik uses bind mounts (./letsencrypt, ./logs) — no named volumes.
DEVBOX_VOLUMES_traefik=""
DEVBOX_VOLUMES_ollama_openwebui="ollama-data openwebui-data"

# Additional host paths that backup.sh must capture verbatim. Letsencrypt
# acme.json is only present when ENABLE_HTTPS=true; backup.sh skips missing
# entries with a warn. .env files are picked up separately per service.
DEVBOX_BACKUP_PATHS="${DEVBOX_HOME}/traefik/letsencrypt/acme.json ${HOME}/.config/devbox ${DEVBOX_HOME}/exegol-workspace"

# Pinned support image for `docker run --rm <img> tar ...` volume export.
# Refreshed by .github/workflows/weekly-rebuild.yml via an opened PR,
# never auto-mutated on `main`.
ALPINE_BACKUP_IMAGE="alpine@sha256:f27cad9117495d32d067133afff942cb2dc745dfe9163e949f6bfe8a6a245339"

# =============================================================================
# Accessors
# =============================================================================

# Normalize service slug for use in variable names (dash → underscore).
devbox_svc_norm() {
  printf '%s' "$1" | tr '-' '_'
}

# Uppercase form for config.env emission keys (COMPOSE_FILE_<SVC>).
devbox_svc_upper() {
  printf '%s' "$1" | tr 'a-z-' 'A-Z_'
}

# Read a per-service contract value.
# Usage: devbox_get <service> <key>
#   key: DIR | COMPOSE | COMPOSE_HTTPS | CONTAINERS | HOST | VOLUMES
devbox_get() {
  svc_norm=$(devbox_svc_norm "$1")
  varname="DEVBOX_${2}_${svc_norm}"
  eval "printf '%s' \"\${${varname}:-}\""
  unset svc_norm varname
}

# Compute the standardized config.env key name for a service's compose chain.
# e.g. devbox_compose_chain_key ollama-openwebui  →  COMPOSE_FILE_OLLAMA_OPENWEBUI
devbox_compose_chain_key() {
  printf 'COMPOSE_FILE_%s' "$(devbox_svc_upper "$1")"
}

# Look up the actual compose chain string for a service from the loaded
# config.env (which sets COMPOSE_FILE_<UPPER> variables). Returns the empty
# string if the variable is unset.
devbox_compose_chain_for() {
  key=$(devbox_compose_chain_key "$1")
  eval "printf '%s' \"\${${key}:-}\""
  unset key
}

# Print a non-blocking WARN line when the installed copy of this file
# differs from the repo copy. Sourced by start-all, stop-all, etc. The repo
# copy is discovered by walking up from BASH_SOURCE for this file (helpers
# pass their own SCRIPT_DIR); falls back silently if the repo copy is not
# reachable (e.g., installed-only host).
#
# Usage: devbox_contract_warn_drift <script_dir_of_caller>
devbox_contract_warn_drift() {
  caller_dir="${1:-}"
  installed="${DEVBOX_HOME}/lib/devbox-contract.sh"
  [ -n "${caller_dir}" ] && [ -f "${installed}" ] || { unset caller_dir installed; return 0; }
  for candidate in \
      "${caller_dir}/../lib/devbox-contract.sh" \
      "${caller_dir}/../../scripts/lib/devbox-contract.sh"; do
      if [ -f "${candidate}" ] && ! cmp -s "${installed}" "${candidate}"; then
          echo "[WARN] installed contract differs from repo copy at ${candidate}." >&2
          echo "[WARN] Re-run setup.sh to resync; helpers continue with installed copy." >&2
          break
      fi
  done
  unset caller_dir installed candidate
}
