#!/usr/bin/env bash
# Stop every devbox service in reverse dependency order. Volumes are kept.
set -euo pipefail

export DEVBOX_HOME="${DEVBOX_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=../lib/devbox-contract.sh
. "${DEVBOX_HOME}/lib/devbox-contract.sh"

for (( i = ${#DEVBOX_SERVICES[@]} - 1; i >= 0; i-- )); do
    svc="${DEVBOX_SERVICES[i]}"
    echo "-> ${svc}"
    ( cd "${DEVBOX_HOME}/${svc}" && docker compose down )
done
