#!/usr/bin/env bash
# CI smoke test: bring up each service, verify health, tear down.
# Intended for weekly CI. Requires Docker and docker compose v2.
# Exit non-zero on any failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVBOX_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SERVICES_DIR="${DEVBOX_DIR}/services"

FAIL=0
WAIT_TIMEOUT="${SMOKE_WAIT_TIMEOUT:-120}"

# CI runners start with no Docker networks. setup.sh creates these on real
# hosts; smoke-test must do the same so `external: true` networks resolve.
# Only remove networks we created — otherwise a dev running this on a host
# with live services would have proxy-net yanked out from under them.
CREATED_NETWORKS=()
ensure_external_network() {
    if docker network inspect "$1" >/dev/null 2>&1; then
        return 0
    fi
    docker network create "$1" >/dev/null
    CREATED_NETWORKS+=("$1")
}
cleanup_networks() {
    for net in "${CREATED_NETWORKS[@]}"; do
        docker network rm "${net}" >/dev/null 2>&1 || true
    done
}
ensure_external_network proxy-net
trap cleanup_networks EXIT

for svc_dir in "${SERVICES_DIR}"/*/; do
    svc=$(basename "${svc_dir}")
    compose_yml="${svc_dir}/docker-compose.yml"
    lock_yml="${svc_dir}/docker-compose.lock.yml"

    if [ ! -f "${compose_yml}" ]; then
        echo "  [SKIP] services/${svc} — no docker-compose.yml"
        continue
    fi

    echo "Smoke testing services/${svc}..."

    COMPOSE_ARGS=(-f docker-compose.yml)
    if [ -f "${lock_yml}" ]; then
        COMPOSE_ARGS+=(-f docker-compose.lock.yml)
    fi

    # Bring up
    if ( cd "${svc_dir}" && \
         docker compose "${COMPOSE_ARGS[@]}" up -d \
             --wait --wait-timeout "${WAIT_TIMEOUT}" ); then
        echo "  [OK] services/${svc} started and healthy"
    else
        echo "  [FAIL] services/${svc} failed to start or become healthy" >&2
        FAIL=$((FAIL+1))
    fi

    # Always tear down
    ( cd "${svc_dir}" && docker compose "${COMPOSE_ARGS[@]}" down -v ) || true
    echo "  [OK] services/${svc} torn down"
    echo ""
done

if [ "${FAIL}" -gt 0 ]; then
    echo "[FAIL] ${FAIL} smoke test failure(s)." >&2
    exit 1
fi
echo "[OK] All smoke tests passed."
