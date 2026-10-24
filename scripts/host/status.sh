#!/usr/bin/env bash
# Show service health, access URLs and where the credentials live.
set -euo pipefail

export DEVBOX_HOME="${DEVBOX_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=../lib/devbox-contract.sh
. "${DEVBOX_HOME}/lib/devbox-contract.sh"

https="$(devbox_config_get ENABLE_HTTPS false)"
domain="$(devbox_config_get DOMAIN)"
ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
ip="${ip:-$(devbox_config_get TAILSCALE_IP '<tailscale-ip>')}"

echo "Services"
for svc in "${DEVBOX_SERVICES[@]}"; do
    for c in $(devbox_get "${svc}" CONTAINERS); do
        state=$(docker inspect -f '{{.State.Status}}{{if .State.Health}} ({{.State.Health.Status}}){{end}}' "${c}" 2>/dev/null || echo "absent")
        printf '  %-22s %s\n' "${c}" "${state}"
    done
done
for c in $(docker ps --format '{{.Names}}' | grep '^exegol-' || true); do
    printf '  %-22s running (rotate VNC password: %s/exegol-reset-vnc.sh %s)\n' "${c}" "${DEVBOX_HOME}" "${c}"
done

echo ""
echo "Tailscale"
tailscale status 2>/dev/null | head -n5 | sed 's/^/  /' || echo "  not connected"

echo ""
echo "Access (clients resolve these names to ${ip})"
echo "  http://ai.internal        Open WebUI"
echo "  http://ollama.internal    Ollama API (basic auth: ${DEVBOX_SECRETS_DIR}/ollama-auth.txt)"
echo "  http://traefik.internal   Traefik dashboard (basic auth: ${DEVBOX_SECRETS_DIR}/traefik-dashboard.txt)"
if [ "${https}" = true ]; then
    echo "  https://ai.${domain}  https://ollama.${domain}  (Let's Encrypt)"
fi
