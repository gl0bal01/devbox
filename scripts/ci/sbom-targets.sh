#!/usr/bin/env bash
# CI SBOM helper: enumerate locked image references from docker-compose.lock.yml files.
# Output: one image reference per line (suitable for: syft <image>).
# Exit non-zero if no lock files found.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVBOX_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SERVICES_DIR="${DEVBOX_DIR}/services"

FOUND=0

for lock_yml in "${SERVICES_DIR}"/*/docker-compose.lock.yml; do
    if [ ! -f "${lock_yml}" ]; then
        continue
    fi
    # svc used only for future diagnostic output; suppress SC2034
    # shellcheck disable=SC2034
    svc=$(basename "$(dirname "${lock_yml}")")

    # Extract image references with digest pins (image: name@sha256:...)
    # Also handles image: name:tag@sha256:... forms
    while IFS= read -r line; do
        # Strip leading whitespace and 'image:' prefix
        img=$(printf '%s' "${line}" | sed 's/^[[:space:]]*image:[[:space:]]*//')
        if [ -n "${img}" ]; then
            echo "${img}"
            FOUND=$((FOUND+1))
        fi
    done < <(grep -E '^\s+image:\s+\S+@sha256:' "${lock_yml}" || true)
done

if [ "${FOUND}" -eq 0 ]; then
    echo "[ERROR] No locked image references found. Run scripts/update-images.sh --apply first." >&2
    exit 1
fi
