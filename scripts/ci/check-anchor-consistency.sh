#!/usr/bin/env bash
# CI: verify x-logging: anchor blocks are identical across all service compose files.
# Drift in logging config means some containers may not have log rotation.
# Exit non-zero if any file diverges.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVBOX_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SERVICES_DIR="${DEVBOX_DIR}/services"

REFERENCE_SHA=""
REFERENCE_FILE=""
FAIL=0

for compose_yml in "${SERVICES_DIR}"/*/docker-compose.yml; do
    svc=$(basename "$(dirname "${compose_yml}")")

    # Extract x-logging: block using awk:
    # from line matching ^x-logging: until first non-indented non-empty line
    block=$(awk '
        /^x-logging:/ { in_block=1; print; next }
        in_block && /^[^ \t]/ && NF > 0 { in_block=0 }
        in_block { print }
    ' "${compose_yml}")

    if [ -z "${block}" ]; then
        echo "  [SKIP] services/${svc}/docker-compose.yml — no x-logging: block"
        continue
    fi

    sha=$(printf '%s' "${block}" | sha256sum | awk '{print $1}')
    echo "  services/${svc}: ${sha}"

    if [ -z "${REFERENCE_SHA}" ]; then
        REFERENCE_SHA="${sha}"
        REFERENCE_FILE="services/${svc}/docker-compose.yml"
    elif [ "${sha}" != "${REFERENCE_SHA}" ]; then
        echo "  [DRIFT] services/${svc}/docker-compose.yml x-logging block differs" >&2
        echo "          Reference: ${REFERENCE_FILE} (${REFERENCE_SHA})" >&2
        echo "          This file: ${sha}" >&2
        FAIL=$((FAIL+1))
    fi
done

echo ""
if [ "${FAIL}" -gt 0 ]; then
    echo "[FAIL] x-logging anchor is inconsistent across ${FAIL} file(s)." >&2
    exit 1
fi
if [ -z "${REFERENCE_SHA}" ]; then
    echo "[WARN] No x-logging blocks found in any compose file."
    exit 0
fi
echo "[OK] All x-logging blocks are consistent (${REFERENCE_SHA})."
