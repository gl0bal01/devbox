#!/usr/bin/env bash
# Validate every compose chain setup.sh can emit (HTTP, HTTPS, GPU; always
# with the digest lock) and assert no published port can bind all
# interfaces. Offline: placeholders stand in for runtime values.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=../lib/devbox-lib.sh
. scripts/lib/devbox-lib.sh

export TAILSCALE_IP=100.64.0.1 DOMAIN=example.com WEBUI_SECRET_KEY=placeholder DEVBOX_GID=1000
fail=0
for dir in services/*/; do
    [ -f "${dir}/docker-compose.yml" ] || continue
    for mode in "false none" "true none" "false nvidia" "true nvidia"; do
        read -r https gpu <<<"${mode}"
        chain=$(compose_file_chain "${dir}" "${https}" "${gpu}")
        stub=$(mktemp -d)
        cp -a "${dir}." "${stub}/"
        printf 'OVH_ENDPOINT=ovh-eu\nOVH_APPLICATION_KEY=x\nOVH_APPLICATION_SECRET=x\nOVH_CONSUMER_KEY=x\n' >"${stub}/ovh.env"
        if ! json=$( cd "${stub}" && COMPOSE_FILE="${chain}" docker compose config --format json ); then
            echo "[FAIL] ${dir} ${chain}" >&2
            fail=1
        elif open=$(jq -r '.services | to_entries[] | .key as $s | (.value.ports // [])[] | select((.host_ip // "") | test("^(|0\\.0\\.0\\.0|::)$")) | "\($s):\(.published)"' <<<"${json}") && [ -n "${open}" ]; then
            echo "[FAIL] ${dir} ${chain}: ports bound to all interfaces: ${open}" >&2
            fail=1
        else
            echo "[ok]   ${dir} ${chain}"
        fi
        rm -rf "${stub}"
    done
done
exit "${fail}"
