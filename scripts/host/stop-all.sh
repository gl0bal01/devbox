#!/usr/bin/env bash
# Stop all devbox services in reverse dependency order.
#
# Sources the installed runtime contract and consumes the per-service
# compose chain via devbox_compose_chain_for (reads COMPOSE_FILE_<SVC>
# from ~/.config/devbox/config.env).
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

echo "Stopping all services..."
for (( i=${#DEVBOX_SERVICES[@]}-1; i>=0; i-- )); do
    svc="${DEVBOX_SERVICES[i]}"
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
    echo "  -> Stopping ${svc}..."
    chain="$(devbox_compose_chain_for "${svc}")"
    if [ "${ENABLE_HTTPS}" = "true" ] && [ -n "${chain}" ]; then
        compose_args=()
        IFS=':' read -ra chain_parts <<<"${chain}"
        for part in "${chain_parts[@]}"; do
            [ -n "${part}" ] && [ -f "${dir}/${part}" ] && compose_args+=("-f" "${part}")
        done
        if [ ${#compose_args[@]} -gt 0 ]; then
            ( cd "${dir}" && docker compose "${compose_args[@]}" down )
        else
            ( cd "${dir}" && docker compose down )
        fi
    else
        ( cd "${dir}" && docker compose down )
    fi
done

echo ""
echo "All services stopped."
