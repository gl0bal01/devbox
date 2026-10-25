#!/usr/bin/env bash
# Bring up each service from its digest lock, wait for health checks, tear
# down. Runs on a scratch copy under its own project names (devbox-smoke-*),
# and refuses to run next to an installed stack because container names are
# fixed. Used by the monthly jobs to validate locks before a PR or release.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../lib/devbox-contract.sh
. scripts/lib/devbox-contract.sh

for svc in "${DEVBOX_SERVICES[@]}"; do
    for c in $(devbox_get "${svc}" CONTAINERS); do
        if docker ps -a --format '{{.Names}}' | grep -qx "${c}"; then
            echo "Container ${c} exists: refusing to run next to a devbox stack (use a CI runner or make e2e)." >&2
            exit 1
        fi
    done
done

work=$(mktemp -d)
created_net=false
compose() { ( cd "${work}/$1" && COMPOSE_PROJECT_NAME="devbox-smoke-$1" docker compose "${@:2}" ); }
cleanup() {
    local svc
    for svc in "${DEVBOX_SERVICES[@]}"; do
        if [ -d "${work}/${svc}" ]; then compose "${svc}" down -v --remove-orphans >/dev/null 2>&1 || true; fi
    done
    if ${created_net}; then docker network rm proxy-net >/dev/null 2>&1 || true; fi
    rm -rf "${work}"
}
trap cleanup EXIT

if ! docker network inspect proxy-net >/dev/null 2>&1; then
    docker network create proxy-net >/dev/null
    created_net=true
fi

fail=0
for svc in "${DEVBOX_SERVICES[@]}"; do
    mkdir -p "${work}/${svc}"
    cp -a "services/${svc}/." "${work}/${svc}/"
    printf 'COMPOSE_FILE=docker-compose.yml:docker-compose.lock.yml\nTAILSCALE_IP=127.0.0.1\nDEVBOX_GID=%s\nWEBUI_SECRET_KEY=%s\n' \
        "$(id -g)" "$(openssl rand -hex 24)" >"${work}/${svc}/.env"
    echo "-> ${svc}"
    if compose "${svc}" up -d --quiet-pull --wait --wait-timeout "${SMOKE_WAIT_TIMEOUT:-300}"; then
        echo "[ok]   ${svc} healthy"
    else
        compose "${svc}" ps -a || true
        compose "${svc}" logs --tail 50 || true
        echo "[FAIL] ${svc}" >&2
        fail=1
    fi
done
exit "${fail}"
