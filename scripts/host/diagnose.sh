#!/usr/bin/env bash
# Bundle diagnostic output for devbox incident reports.
# Output: /tmp/devbox-diagnose-<timestamp>.tar.gz
#
# Usage: diagnose.sh [--dry-run]
set -euo pipefail

DRY_RUN=false
for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown argument: ${arg}" >&2; exit 1 ;;
    esac
done

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUTDIR="/tmp/devbox-diagnose-${TIMESTAMP}"
ARCHIVE="/tmp/devbox-diagnose-${TIMESTAMP}.tar.gz"
DEVBOX_DIR="${HOME}/docker/devbox"

# run_cmd: execute or print depending on --dry-run
run_cmd() {
    if [ "${DRY_RUN}" = "true" ]; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

# capture: run command, append output to a file in OUTDIR
capture() {
    local label="$1"; shift
    local outfile="${OUTDIR}/${label}.txt"
    echo "  -> ${label}"
    if [ "${DRY_RUN}" = "true" ]; then
        echo "[DRY-RUN] $* > ${outfile}"
        return
    fi
    mkdir -p "${OUTDIR}"
    # Run with || true so a failing command doesn't abort the whole diagnose
    { "$@" 2>&1 || true; } > "${outfile}"
}

echo "devbox diagnose"
echo "  Timestamp: ${TIMESTAMP}"
if [ "${DRY_RUN}" = "true" ]; then
    echo "  Mode: DRY-RUN (commands printed, not executed)"
fi
echo ""

[ "${DRY_RUN}" = "false" ] && mkdir -p "${OUTDIR}"

# -----------------------------------------------------------------------
# 1. docker compose ps per service dir
# -----------------------------------------------------------------------
echo "1. Compose status per service..."
for svc_dir in "${DEVBOX_DIR}/services"/*/; do
    svc=$(basename "${svc_dir}")
    capture "compose-ps-${svc}" bash -c "cd '${svc_dir}' && docker compose ps"
done

# -----------------------------------------------------------------------
# 2. docker logs --tail=500 per core container
# -----------------------------------------------------------------------
echo "2. Container logs (last 500 lines each)..."
for cname in traefik ollama open-webui docker-socket-proxy; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$" || [ "${DRY_RUN}" = "true" ]; then
        capture "logs-${cname}" docker logs --tail=500 "${cname}"
    fi
done

# -----------------------------------------------------------------------
# 3. Tailscale status
# -----------------------------------------------------------------------
echo "3. Tailscale status..."
capture "tailscale-status" tailscale status

# -----------------------------------------------------------------------
# 4. UFW status
# -----------------------------------------------------------------------
echo "4. UFW status..."
capture "ufw-status" sudo ufw status verbose

# -----------------------------------------------------------------------
# 5. Socket/port listing
# -----------------------------------------------------------------------
echo "5. Listening sockets..."
capture "ss-tlnp" ss -tlnp

# -----------------------------------------------------------------------
# 6. Config (secrets redacted)
# -----------------------------------------------------------------------
echo "6. Config (redacted)..."
CONFIG_ENV="${HOME}/.config/devbox/config.env"
if [ -f "${CONFIG_ENV}" ]; then
    capture "config-env-redacted" bash -c \
        "grep -v -iE 'token|password|secret|key' '${CONFIG_ENV}'"
else
    capture "config-env-redacted" echo "(no config at ${CONFIG_ENV})"
fi

# -----------------------------------------------------------------------
# 7. Lock-file SHA256s
# -----------------------------------------------------------------------
echo "7. docker-compose.lock.yml SHA256s..."
capture "lockfile-sha256" bash -c \
    "find '${DEVBOX_DIR}/services' -name 'docker-compose.lock.yml' \
     -exec sha256sum {} \;"

# -----------------------------------------------------------------------
# 8. Log config via docker inspect
# -----------------------------------------------------------------------
echo "8. Container log config..."
capture "log-config" bash -c \
    "docker ps -q | xargs -r docker inspect \
        --format '{{.Name}}: {{json .HostConfig.LogConfig}}' 2>/dev/null || true"

# -----------------------------------------------------------------------
# Bundle
# -----------------------------------------------------------------------
if [ "${DRY_RUN}" = "false" ]; then
    run_cmd tar -czf "${ARCHIVE}" -C /tmp "$(basename "${OUTDIR}")"
    rm -rf "${OUTDIR}"
    echo ""
    echo "[OK] Diagnostic bundle: ${ARCHIVE}"
    ls -lh "${ARCHIVE}"
else
    echo ""
    echo "[DRY-RUN] Would create: ${ARCHIVE}"
fi
