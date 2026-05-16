#!/usr/bin/env bash
# Show status of all devbox services, security posture, and access URLs.
#
# Sources the installed runtime contract and reads ENABLE_HTTPS /
# COMPOSE_FILE_TRAEFIK / COMPOSE_FILE_OLLAMA from ~/.config/devbox/config.env
# (emitted by setup.sh).
set -euo pipefail

CONFIG_ENV="${HOME}/.config/devbox/config.env"
DEVBOX_HOME="${DEVBOX_HOME:-${HOME}/docker}"
CONTRACT="${DEVBOX_HOME}/lib/devbox-contract.sh"

if [ -f "${CONTRACT}" ]; then
    # shellcheck disable=SC1090
    . "${CONTRACT}"
fi

if [ -f "${CONFIG_ENV}" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${CONFIG_ENV}"
    set +a
fi

ENABLE_HTTPS="${ENABLE_HTTPS:-false}"

echo "Docker Services Status"
echo "======================================================================="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""

echo "Configuration"
echo "======================================================================="
echo "  ENABLE_HTTPS         : ${ENABLE_HTTPS}"
if [ "${DEVBOX_SERVICES+set}" = "set" ]; then
    for _svc in "${DEVBOX_SERVICES[@]}"; do
        _key="$(devbox_compose_chain_key "${_svc}")"
        _val="$(devbox_compose_chain_for "${_svc}")"
        if [ -n "${_val}" ]; then
            printf '  %-21s: %s\n' "${_key}" "${_val}"
        else
            printf '  %-21s: (not set, HTTP mode)\n' "${_key}"
        fi
    done
fi
if command -v flock >/dev/null 2>&1; then
    echo "  flock                : available"
else
    echo "  flock                : NOT FOUND (install util-linux)"
fi
echo ""

echo "Security Status"
echo "======================================================================="
if docker ps --format '{{.Names}}' | grep -q docker-socket-proxy; then
    echo "  [OK] Docker socket proxy: running"
else
    echo "  [WARN] Docker socket proxy: not running"
fi

ROOT_CONTAINERS=$(docker ps -q | xargs -r docker inspect --format '{{.Name}} {{.Config.User}}' 2>/dev/null | grep -E "^/[^ ]+ (0|root|)$" | cut -d'/' -f2 | cut -d' ' -f1 || true)
if [ -n "${ROOT_CONTAINERS}" ]; then
    echo "  [WARN] Containers running as root: ${ROOT_CONTAINERS}"
else
    echo "  [OK] No containers running as root (or expected ones only)"
fi
echo ""

echo "Tailscale Status"
echo "======================================================================="
tailscale status 2>/dev/null || echo "  Tailscale not connected"
echo ""

# Exegol containers
EXEGOL_CONTAINERS=$(docker ps --format '{{.Names}}' | grep '^exegol-' || true)
if [ -n "${EXEGOL_CONTAINERS}" ]; then
    echo "Exegol Containers"
    echo "======================================================================="
    while IFS= read -r cname; do
        echo "  Running: ${cname}"
        echo "  To rotate VNC password: ${DEVBOX_HOME}/exegol-reset-vnc.sh ${cname}"
    done <<< "${EXEGOL_CONTAINERS}"
    echo ""
fi

echo "Access URLs (add to /etc/hosts on your laptop):"
echo "======================================================================="
TSIP=$(tailscale ip -4 2>/dev/null || echo "TAILSCALE_IP")
echo "  ${TSIP}  ai.internal traefik.internal ollama.internal exegol.internal"
echo ""
if [ "${ENABLE_HTTPS}" = "true" ]; then
    echo "  https://ai.internal        -> Open WebUI"
    echo "  https://traefik.internal   -> Traefik Dashboard (requires auth)"
    echo "  https://ollama.internal    -> Ollama API (requires basic auth)"
else
    echo "  http://ai.internal         -> Open WebUI"
    echo "  http://traefik.internal    -> Traefik Dashboard (requires auth)"
    echo "  http://ollama.internal     -> Ollama API (requires basic auth)"
fi
echo ""
echo "Ollama basic-auth credential: ${DEVBOX_HOME}/.secrets/ollama-auth.txt"
echo "  Rotate with: ${DEVBOX_HOME}/rotate-ollama-auth.sh"
