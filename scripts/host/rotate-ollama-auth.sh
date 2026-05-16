#!/usr/bin/env bash
# =============================================================================
# rotate-ollama-auth.sh — rotate the basic-auth credential for ollama.internal
# =============================================================================
#
# OPEN WEBUI SIDE EFFECT: NONE.
#
# Open WebUI reaches Ollama on the internal Compose network at
# http://ollama:11434 (see services/ollama-openwebui/docker-compose.yml,
# OLLAMA_BASE_URL). That path does not traverse Traefik and does not present
# basic-auth credentials. Rotating the ollama-auth@file middleware therefore
# affects ONLY external clients hitting http://ollama.internal (Tailscale
# users with curl, IDE plugins, etc). Open WebUI continues to work unchanged.
#
# The new plaintext credential is written to
# ${DEVBOX_HOME}/.secrets/ollama-auth.txt (mode 0600) — point any external
# client at that file.
# =============================================================================

set -euo pipefail

DEVBOX_HOME="${DEVBOX_HOME:-${HOME}/docker}"
AUTH_YML="${DEVBOX_HOME}/traefik/dynamic/ollama-auth.yml"
SECRETS_DIR="${DEVBOX_HOME}/.secrets"
SECRET_FILE="${SECRETS_DIR}/ollama-auth.txt"
AUTH_USER="ollama"

if [ ! -d "${DEVBOX_HOME}" ]; then
    echo "[ERROR] DEVBOX_HOME (${DEVBOX_HOME}) does not exist. Run setup.sh first." >&2
    exit 1
fi
if [ ! -f "${AUTH_YML}" ]; then
    echo "[ERROR] ${AUTH_YML} not found. Cannot rotate." >&2
    exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
    echo "[ERROR] openssl required for password generation and htpasswd hash." >&2
    exit 1
fi

new_pass=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
new_hash=$(openssl passwd -apr1 "${new_pass}")

# Yaml escape: htpasswd hashes use $ which must be doubled inside a YAML
# basic-auth users list so Traefik does not Compose-interpolate it. The
# Traefik file provider does not interpolate, but operators sometimes copy
# the file into a Compose label by mistake — be defensive.
new_hash_escaped="${new_hash//\$/\$\$}"

umask 077
install -d -m 0700 "${SECRETS_DIR}"
tmp=$(mktemp "${AUTH_YML}.XXXXXX")
cat >"${tmp}" <<EOF
# Rendered by rotate-ollama-auth.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Used by Traefik file provider; mode 0600.
http:
  middlewares:
    ollama-auth:
      basicAuth:
        users:
          - "${AUTH_USER}:${new_hash_escaped}"
EOF
chmod 0600 "${tmp}"
mv "${tmp}" "${AUTH_YML}"

tmp_secret=$(mktemp "${SECRET_FILE}.XXXXXX")
printf '%s:%s\n' "${AUTH_USER}" "${new_pass}" >"${tmp_secret}"
chmod 0600 "${tmp_secret}"
mv "${tmp_secret}" "${SECRET_FILE}"

echo "[OK] ollama-auth rotated."
echo "  Middleware YAML : ${AUTH_YML}"
echo "  New credential  : ${SECRET_FILE} (mode 0600)"
echo "  User            : ${AUTH_USER}"
echo ""

# Verify the assumed Open WebUI -> Ollama internal-DNS path. If the running
# openwebui container points OLLAMA_BASE_URL at the internal ollama service,
# rotation is safe (no auth crosses that hop). If it points anywhere else
# (e.g., http://ollama.internal — i.e., back through Traefik), warn loudly
# because the rotated credential will break it.
if command -v docker >/dev/null 2>&1 && \
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^openwebui$'; then
    base_url=$(docker inspect -f \
        '{{range $i, $e := .Config.Env}}{{if eq (index (split $e "=") 0) "OLLAMA_BASE_URL"}}{{$e}}{{end}}{{end}}' \
        openwebui 2>/dev/null | sed 's/^OLLAMA_BASE_URL=//')
    case "${base_url}" in
        http://ollama:*)
            echo "Open WebUI -> Ollama via internal Compose DNS (${base_url}); rotation is safe."
            ;;
        '')
            echo "[WARN] openwebui has no OLLAMA_BASE_URL env; cannot confirm internal path."
            ;;
        *)
            echo "[WARN] openwebui OLLAMA_BASE_URL=${base_url} crosses Traefik basic-auth."
            echo "[WARN] Update Open WebUI's OLLAMA_BASE_URL with the new credential or"
            echo "[WARN] point it at http://ollama:11434 (internal) before next request."
            ;;
    esac
    unset base_url
else
    echo "(openwebui container not running; Open WebUI side-effect assumed no-op)"
fi
echo "External clients of http://ollama.internal must use the new credential."
