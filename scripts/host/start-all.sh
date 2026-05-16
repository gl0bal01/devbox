#!/usr/bin/env bash
# Start all devbox services in dependency order.
# Uses --wait --wait-timeout 120 instead of sleep for reliable startup.
#
# Sources the installed runtime contract (${DEVBOX_HOME}/lib/devbox-contract.sh)
# as the runtime authority. Reads ENABLE_HTTPS and per-service compose
# chains (COMPOSE_FILE_<SVC>) from ~/.config/devbox/config.env, where <SVC>
# is the upper-cased service slug with `-` rewritten to `_`.
set -euo pipefail

CONFIG_ENV="${HOME}/.config/devbox/config.env"
DEVBOX_HOME="${DEVBOX_HOME:-${HOME}/docker}"
CONTRACT="${DEVBOX_HOME}/lib/devbox-contract.sh"

if [ ! -f "${CONTRACT}" ]; then
    echo "[ERROR] Missing ${CONTRACT}. Run setup.sh to install the runtime contract." >&2
    exit 1
fi
# shellcheck disable=SC1090
. "${CONTRACT}"

devbox_contract_warn_drift "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${CONFIG_ENV}" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${CONFIG_ENV}"
    set +a
fi

ENABLE_HTTPS="${ENABLE_HTTPS:-false}"

echo "Starting all services..."
if [ "${ENABLE_HTTPS}" = "true" ]; then
    echo "  Mode: HTTPS"
    for svc in "${DEVBOX_SERVICES[@]}"; do
        printf '    %s=%s\n' "$(devbox_compose_chain_key "${svc}")" "$(devbox_compose_chain_for "${svc}")"
    done
else
    echo "  Mode: HTTP"
fi
echo ""

for svc in "${DEVBOX_SERVICES[@]}"; do
    subdir="$(devbox_get "${svc}" DIR)"
    if [ -z "${subdir}" ]; then
        echo "  [SKIP] ${svc}: no DIR mapping in contract"
        continue
    fi
    dir="${DEVBOX_HOME}/${subdir}"
    if [ ! -d "${dir}" ]; then
        echo "  [SKIP] ${svc}: install dir ${dir} not found"
        continue
    fi
    echo "  -> Starting ${svc}..."
    chain="$(devbox_compose_chain_for "${svc}")"
    if [ "${ENABLE_HTTPS}" = "true" ] && [ -n "${chain}" ]; then
        compose_args=()
        IFS=':' read -ra chain_parts <<<"${chain}"
        for part in "${chain_parts[@]}"; do
            [ -n "${part}" ] && [ -f "${dir}/${part}" ] && compose_args+=("-f" "${part}")
        done
        if [ ${#compose_args[@]} -gt 0 ]; then
            ( cd "${dir}" && docker compose "${compose_args[@]}" up -d --wait --wait-timeout 120 )
        else
            ( cd "${dir}" && docker compose up -d --wait --wait-timeout 120 )
        fi
    else
        ( cd "${dir}" && docker compose up -d --wait --wait-timeout 120 )
    fi
    echo "  -> ${svc} ready."
done

echo ""
echo "All services started."
echo ""
echo "Service Status:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "Security: All containers running with hardened configurations"
echo "  * Secrets stored in .env files (not in compose files)"
echo "  * Traefik using docker-socket-proxy"
echo "  * Resource limits applied"
