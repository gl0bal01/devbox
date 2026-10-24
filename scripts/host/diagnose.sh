#!/usr/bin/env bash
# Bundle diagnostics for an incident report. Secrets are not collected:
# .env, ovh.env and .secrets are skipped and config.env is filtered.
# Output: ~/devbox-diagnose-<timestamp>.tar.gz (mode 0600)
set -euo pipefail
umask 077

export DEVBOX_HOME="${DEVBOX_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=../lib/devbox-contract.sh
. "${DEVBOX_HOME}/lib/devbox-contract.sh"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT=$(mktemp -d)
trap 'rm -rf "${OUT}"' EXIT
ARCHIVE="${DEVBOX_OWNER_HOME}/devbox-diagnose-${STAMP}.tar.gz"

capture() {
    local name="$1"; shift
    echo "  ${name}"
    { "$@" 2>&1 || true; } >"${OUT}/${name}.txt"
}

for svc in "${DEVBOX_SERVICES[@]}"; do
    capture "compose-ps-${svc}" bash -c "cd '${DEVBOX_HOME}/${svc}' && docker compose ps -a"
    capture "compose-images-${svc}" bash -c "cd '${DEVBOX_HOME}/${svc}' && docker compose images"
    for c in $(devbox_get "${svc}" CONTAINERS); do
        capture "logs-${c}" docker logs --tail 500 "${c}"
    done
done
capture tailscale-status tailscale status
capture ufw-status sudo -n ufw status verbose
capture listeners ss -Hltnp
capture docker-info docker info
capture daemon-json cat /etc/docker/daemon.json
capture config-env grep -vE '^(OVH|.*(SECRET|PASSWORD|TOKEN|KEY))' "${DEVBOX_CONFIG}"
capture security-check "${DEVBOX_HOME}/security-check.sh"

tar -C "${OUT}" -czf "${ARCHIVE}" .
echo "[ok] ${ARCHIVE}"
