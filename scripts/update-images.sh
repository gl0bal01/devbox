#!/usr/bin/env bash
# Refresh docker-compose.lock.yml files for each service.
#
# Usage:
#   ./scripts/update-images.sh --check    # diff against committed lock, exit 1 on drift
#   ./scripts/update-images.sh --apply    # write stabilized lock files
#   ./scripts/update-images.sh --apply --force  # apply even on dirty working tree
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVBOX_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVICES_DIR="${DEVBOX_DIR}/services"

MODE=""
FORCE=false

for arg in "$@"; do
    case "${arg}" in
        --check) MODE="check" ;;
        --apply) MODE="apply" ;;
        --force) FORCE=true ;;
        *) echo "Unknown argument: ${arg}" >&2; exit 1 ;;
    esac
done

if [ -z "${MODE}" ]; then
    echo "Usage: $0 [--check|--apply] [--force]" >&2
    exit 1
fi

ANY_DRIFT=false

for svc_dir in "${SERVICES_DIR}"/*/; do
    svc=$(basename "${svc_dir}")
    compose_yml="${svc_dir}/docker-compose.yml"
    lock_yml="${svc_dir}/docker-compose.lock.yml"

    if [ ! -f "${compose_yml}" ]; then
        echo "  [SKIP] services/${svc} — no docker-compose.yml"
        continue
    fi

    echo "Processing services/${svc}..."

    TMPLOCK="/tmp/new-lock-${svc}.yml.$$"
    trap 'rm -f "${TMPLOCK}"' EXIT INT TERM

    # Generate first pass from the BASE file only. Chaining the existing
    # lock here would let its digest override the base tag, so a tag bump
    # (or an upstream patch release) would never change the resolved digest.
    ( cd "${svc_dir}" && \
      docker compose -f docker-compose.yml \
          config --lock-image-digests > "${TMPLOCK}" )

    # Normalization pass: re-run with the first pass chained so the output
    # takes the canonical `name@sha256:...` form (first pass emits
    # `name:tag@sha256:...`). Always runs; output is idempotent.
    TMPLOCK2="/tmp/new-lock-${svc}-2.yml.$$"
    ( cd "${svc_dir}" && \
      docker compose -f docker-compose.yml -f "${TMPLOCK}" \
          config --lock-image-digests > "${TMPLOCK2}" ) 2>/dev/null || \
    cp "${TMPLOCK}" "${TMPLOCK2}"
    mv "${TMPLOCK2}" "${TMPLOCK}"

    if [ "${MODE}" = "check" ]; then
        if [ ! -f "${lock_yml}" ]; then
            echo "  [DRIFT] No lock file exists for services/${svc}" >&2
            ANY_DRIFT=true
        elif ! diff -u "${lock_yml}" "${TMPLOCK}"; then
            echo "  [DRIFT] services/${svc}/docker-compose.lock.yml differs" >&2
            ANY_DRIFT=true
        else
            echo "  [OK] services/${svc} lock is current"
        fi
        rm -f "${TMPLOCK}"
        continue
    fi

    # --apply: guard against dirty working tree
    if [ "${FORCE}" = "false" ]; then
        if ! git -C "${DEVBOX_DIR}" diff --quiet --exit-code \
                "services/${svc}/docker-compose.lock.yml" 2>/dev/null; then
            echo "  [ERROR] services/${svc}/docker-compose.lock.yml has uncommitted changes." >&2
            echo "          Use --force to overwrite." >&2
            rm -f "${TMPLOCK}"
            exit 1
        fi
    fi

    mv -f "${TMPLOCK}" "${lock_yml}"
    trap - EXIT INT TERM
    echo "  [OK] services/${svc}/docker-compose.lock.yml updated"
done

if [ "${MODE}" = "check" ] && [ "${ANY_DRIFT}" = "true" ]; then
    echo ""
    echo "[DRIFT] One or more lock files are out of date. Run --apply to update." >&2
    exit 1
fi

if [ "${MODE}" = "apply" ]; then
    echo ""
    echo "[OK] All lock files updated."
fi
exit 0
