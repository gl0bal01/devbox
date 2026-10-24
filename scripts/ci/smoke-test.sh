#!/usr/bin/env bash
# Bring up each service from its digest lock, wait for health checks, tear
# down. Runs on a scratch copy so the repo tree stays clean. Used by the
# monthly jobs to validate refreshed locks before opening a PR / releasing.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
work=$(mktemp -d)
created_net=false
cleanup() {
    local d
    for d in "${work}"/*/; do
        [ -f "${d}/docker-compose.yml" ] && ( cd "${d}" && docker compose down -v --remove-orphans >/dev/null 2>&1 ) || true
    done
    ${created_net} && docker network rm proxy-net >/dev/null 2>&1 || true
    rm -rf "${work}"
}
trap cleanup EXIT

if ! docker network inspect proxy-net >/dev/null 2>&1; then
    docker network create proxy-net >/dev/null
    created_net=true
fi

fail=0
for dir in services/*/; do
    svc=$(basename "${dir}")
    mkdir -p "${work}/${svc}"
    cp -a "${dir}." "${work}/${svc}/"
    printf 'COMPOSE_FILE=docker-compose.yml:docker-compose.lock.yml\nTAILSCALE_IP=127.0.0.1\nDEVBOX_GID=%s\nWEBUI_SECRET_KEY=%s\n' \
        "$(id -g)" "$(openssl rand -hex 24)" >"${work}/${svc}/.env"
    echo "-> ${svc}"
    if ( cd "${work}/${svc}" && docker compose up -d --quiet-pull --wait --wait-timeout "${SMOKE_WAIT_TIMEOUT:-240}" ); then
        echo "[ok]   ${svc} healthy"
    else
        ( cd "${work}/${svc}" && docker compose ps -a && docker compose logs --tail 50 ) || true
        echo "[FAIL] ${svc}" >&2
        fail=1
    fi
done
exit "${fail}"
