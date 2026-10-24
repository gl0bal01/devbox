#!/usr/bin/env bash
# Start every devbox service in dependency order and wait until healthy.
# Each service's .env carries COMPOSE_FILE (base + overlays + digest lock).
set -euo pipefail

export DEVBOX_HOME="${DEVBOX_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=../lib/devbox-contract.sh
. "${DEVBOX_HOME}/lib/devbox-contract.sh"

docker network inspect proxy-net >/dev/null 2>&1 || docker network create proxy-net >/dev/null
for svc in "${DEVBOX_SERVICES[@]}"; do
    echo "-> ${svc}"
    ( cd "${DEVBOX_HOME}/${svc}" && docker compose up -d --remove-orphans --wait --wait-timeout 180 )
done
echo ""
docker ps --filter "label=com.docker.compose.project" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
