#!/usr/bin/env bash
# CI: validate docker compose config for each service in HTTP and HTTPS modes.
# Uses dummy interpolation values so compose can parse without real secrets.
# Exit non-zero on any failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVBOX_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SERVICES_DIR="${DEVBOX_DIR}/services"

FAIL=0

# Dummy environment for variable interpolation
export TAILSCALE_IP="100.0.0.0"
export DOMAIN="example.com"
export WEBUI_SECRET_KEY="dummysecret"
export NEXTCLOUD_ADMIN_USER="admin"
export NEXTCLOUD_ADMIN_PASSWORD="dummypass"
export POSTGRES_PASSWORD="dummypass"
export REDIS_PASSWORD="dummypass"
export NEXTCLOUD_TRUSTED_DOMAINS="cloud.example.com"
export COMPOSE_FILE=""

for svc_dir in "${SERVICES_DIR}"/*/; do
    svc=$(basename "${svc_dir}")
    compose_yml="${svc_dir}/docker-compose.yml"

    if [ ! -f "${compose_yml}" ]; then
        echo "  [SKIP] services/${svc} — no docker-compose.yml"
        continue
    fi

    echo "Checking services/${svc}..."

    # HTTP mode
    echo "  -> HTTP mode"
    if ( cd "${svc_dir}" && docker compose -f docker-compose.yml config -q 2>&1 ); then
        echo "     [OK] HTTP"
    else
        echo "     [FAIL] HTTP config invalid for services/${svc}" >&2
        FAIL=$((FAIL+1))
    fi

    # HTTPS mode (if override file exists). Some services (traefik) declare
    # `env_file: .env` in the HTTPS override pointing at OVH credentials. CI
    # doesn't have real credentials, so stage a stub .env in a tempdir copy and
    # validate from there. The real services/<svc>/ tree is left untouched.
    HTTPS_OVERRIDE="${svc_dir}/docker-compose.https.yml"
    if [ -f "${HTTPS_OVERRIDE}" ]; then
        echo "  -> HTTPS mode"
        STUB_DIR=$(mktemp -d)
        cp -a "${svc_dir}." "${STUB_DIR}/"
        if [ ! -f "${STUB_DIR}/.env" ]; then
            cat >"${STUB_DIR}/.env" <<'STUB_ENV'
OVH_ENDPOINT=ovh-eu
OVH_APPLICATION_KEY=stub
OVH_APPLICATION_SECRET=stub
OVH_CONSUMER_KEY=stub
WEBUI_SECRET_KEY=stub
ENABLE_SIGNUP=false
STUB_ENV
        fi
        if ( cd "${STUB_DIR}" && \
             docker compose -f docker-compose.yml -f docker-compose.https.yml config -q 2>&1 ); then
            echo "     [OK] HTTPS"
        else
            echo "     [FAIL] HTTPS config invalid for services/${svc}" >&2
            FAIL=$((FAIL+1))
        fi
        rm -rf "${STUB_DIR}"
    fi
done

echo ""
if [ "${FAIL}" -gt 0 ]; then
    echo "[FAIL] ${FAIL} compose config failure(s)." >&2
    exit 1
fi
echo "[OK] All compose configs valid."
