#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# =============================================================================
# DEVBOX RUNTIME CONTRACT
# =============================================================================
# Single source of truth for install layout, service identities, container
# names, Traefik hosts and backup scope. setup.sh sources the repo copy and
# installs it to ${DEVBOX_HOME}/lib/devbox-contract.sh; installed helpers
# source that copy. `setup.sh --check` reports drift between the two.
#
# Sourced by bash only (DEVBOX_SERVICES is an array). Keep it declarative:
# constants plus two tiny accessors.
# =============================================================================

# Bump on schema-incompatible changes.
#   v1 — initial contract
#   v2 — DEVBOX_USER, compose-chain accessors
#   v3 — compose chain moved to each service's .env (native COMPOSE_FILE);
#        volumes discovered by compose labels; owner-relative paths
DEVBOX_CONTRACT_VERSION=3

# Install root. Helpers export DEVBOX_HOME from their own location before
# sourcing this file, so it resolves correctly under sudo (HOME=/root).
DEVBOX_HOME="${DEVBOX_HOME:-${HOME}/docker}"

# Everything else hangs off the owner's home (the parent of DEVBOX_HOME).
DEVBOX_OWNER_HOME="${DEVBOX_HOME%/*}"
DEVBOX_CONFIG_DIR="${DEVBOX_OWNER_HOME}/.config/devbox"
DEVBOX_CONFIG="${DEVBOX_CONFIG_DIR}/config.env"
DEVBOX_SECRETS_DIR="${DEVBOX_HOME}/.secrets"
DEVBOX_BACKUP_DIR="${DEVBOX_OWNER_HOME}/.local/share/devbox/backups"

# Ordered service list; each is a Compose project of the same name living in
# ${DEVBOX_HOME}/<service>. Dependencies first.
DEVBOX_SERVICES=(traefik ollama-openwebui)

# Container names per service (space-separated). Pinned against the compose
# files by tests/contract/contract.bats.
DEVBOX_CONTAINERS_traefik="traefik docker-socket-proxy"
DEVBOX_CONTAINERS_ollama_openwebui="ollama openwebui"

# Traefik hosts per service. Every host needs a matching Host(...) router rule.
DEVBOX_HOST_traefik="traefik.internal"
DEVBOX_HOST_ollama_openwebui="ai.internal ollama.internal"

# Compose volume keys skipped by backup.sh. Ollama models are large and
# re-pullable; back up `ollama list` output instead. Every other volume,
# including Traefik's ACME state (HTTPS mode), is archived.
DEVBOX_BACKUP_EXCLUDE_VOLUMES="ollama-data"

# Host paths captured by backup.sh, relative to DEVBOX_OWNER_HOME. Missing
# entries are skipped. Each service's .env is added automatically.
DEVBOX_BACKUP_PATHS="docker/.secrets .config/devbox docker/exegol-workspace"

# Read a per-service contract value.
# Usage: devbox_get <service> <CONTAINERS|HOST>
devbox_get() {
    local var="DEVBOX_${2}_${1//-/_}"
    printf '%s' "${!var:-}"
}

# Read one KEY=value from config.env without sourcing it.
# Usage: devbox_config_get <KEY> [default]
devbox_config_get() {
    local val=""
    [ -f "${DEVBOX_CONFIG}" ] && val=$(sed -n "s/^${1}=//p" "${DEVBOX_CONFIG}" | tail -n1)
    printf '%s' "${val:-${2:-}}"
}
