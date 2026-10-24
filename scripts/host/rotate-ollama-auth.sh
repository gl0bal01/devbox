#!/usr/bin/env bash
# Rotate the basic-auth credential for http(s)://ollama.<host>.
#
# Writes a new password to .secrets/ollama-auth.txt and re-renders the
# Traefik middleware from it; Traefik's file watcher applies it within
# seconds. Open WebUI is unaffected: it reaches Ollama directly at
# http://ollama:11434 without crossing Traefik. setup.sh re-renders from the
# same file, so the rotation survives re-runs.
set -euo pipefail

export DEVBOX_HOME="${DEVBOX_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=../lib/devbox-contract.sh
. "${DEVBOX_HOME}/lib/devbox-contract.sh"
# shellcheck source=../lib/devbox-lib.sh
. "${DEVBOX_HOME}/lib/devbox-lib.sh"
umask 077

CRED="${DEVBOX_SECRETS_DIR}/ollama-auth.txt"
rotate_credential "${CRED}" ollama
render_basic_auth ollama-auth "${CRED}" "${DEVBOX_HOME}/traefik/dynamic/ollama-auth.yml"
log "Rotated. New credential: ${CRED}"

base_url=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' openwebui 2>/dev/null | sed -n 's/^OLLAMA_BASE_URL=//p')
case "${base_url}" in
    ""|http://ollama:*) ;;
    *) warn "Open WebUI uses OLLAMA_BASE_URL=${base_url}, which crosses Traefik: update its credential." ;;
esac
