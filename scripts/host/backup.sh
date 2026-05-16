#!/usr/bin/env bash
# Backup persistent devbox volumes (named volumes via docker run + tar) and
# host paths into a single archive, optionally encrypted with GPG or age.
#
# Output: ~/.local/share/devbox/backups/devbox-backup-<timestamp>.tar.gz[.gpg|.age]
#
# Named volumes (declared in services/*/docker-compose.yml + listed in
# devbox-contract.sh DEVBOX_VOLUMES_*) are exported with:
#   docker run --rm -v <vol>:/data -v <staging>:/backup ${ALPINE_BACKUP_IMAGE} \
#       tar -czf /backup/<vol>.tgz -C /data .
# A `docker volume inspect` precheck skips missing volumes with a warn.
set -euo pipefail

DEVBOX_HOME="${DEVBOX_HOME:-${HOME}/docker}"
CONTRACT="${DEVBOX_HOME}/lib/devbox-contract.sh"
if [ ! -f "${CONTRACT}" ]; then
    echo "[ERROR] Missing ${CONTRACT}. Run setup.sh to install the runtime contract." >&2
    exit 1
fi
# shellcheck disable=SC1090
. "${CONTRACT}"

BACKUP_DIR="${HOME}/.local/share/devbox/backups"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
STAGING="${BACKUP_DIR}/staging-${TIMESTAMP}"
ARCHIVE_BASE="${BACKUP_DIR}/devbox-backup-${TIMESTAMP}.tar.gz"

CONFIG_ENV="${HOME}/.config/devbox/config.env"
ENABLE_HTTPS="false"
if [ -f "${CONFIG_ENV}" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${CONFIG_ENV}"
    set +a
fi

mkdir -p "${STAGING}"
trap 'rm -rf "${STAGING}"' EXIT

# ---------------------------------------------------------------------------
# Phase 1: tar each named volume into the staging dir.
# ---------------------------------------------------------------------------
declare -a VOLUME_ARCHIVES=()
if [ "${DEVBOX_SERVICES+set}" = "set" ]; then
    for svc in "${DEVBOX_SERVICES[@]}"; do
        vols="$(devbox_get "${svc}" VOLUMES)"
        for vol in ${vols}; do
            if ! docker volume inspect "${vol}" >/dev/null 2>&1; then
                echo "  [SKIP] volume ${vol} not found (service may not be started)"
                continue
            fi
            archive="${STAGING}/${vol}.tgz"
            echo "  -> Exporting volume ${vol}..."
            docker run --rm \
                -v "${vol}:/data:ro" \
                -v "${STAGING}:/backup" \
                "${ALPINE_BACKUP_IMAGE}" \
                tar -czf "/backup/${vol}.tgz" -C /data .
            VOLUME_ARCHIVES+=("${archive}")
        done
    done
fi

# ---------------------------------------------------------------------------
# Phase 2: collect host paths into the staging dir (.env files, acme.json,
# exegol-workspace, ~/.config/devbox).
# ---------------------------------------------------------------------------
declare -a HOST_PATHS=()

# Per-service .env files (mode 0600, contain secrets).
if [ "${DEVBOX_SERVICES+set}" = "set" ]; then
    for svc in "${DEVBOX_SERVICES[@]}"; do
        subdir="$(devbox_get "${svc}" DIR)"
        envfile="${DEVBOX_HOME}/${subdir}/.env"
        if [ -f "${envfile}" ]; then
            HOST_PATHS+=("${envfile}")
        fi
    done
fi

# Operator-managed .secrets dir (ollama-auth.txt, etc).
if [ -d "${DEVBOX_HOME}/.secrets" ]; then
    HOST_PATHS+=("${DEVBOX_HOME}/.secrets")
fi

# Contract-declared backup paths.
if [ "${DEVBOX_BACKUP_PATHS+set}" = "set" ]; then
    for p in ${DEVBOX_BACKUP_PATHS}; do
        if [ -e "${p}" ]; then
            HOST_PATHS+=("${p}")
        else
            echo "  [SKIP] not found: ${p}"
        fi
    done
fi

# letsencrypt acme.json is only useful in HTTPS mode; the contract path is
# already in DEVBOX_BACKUP_PATHS but we keep a guard in case operator runs
# this outside HTTPS mode.
if [ "${ENABLE_HTTPS}" != "true" ]; then
    echo "  [INFO] ENABLE_HTTPS=false; skipping ACME state if not present."
fi

if [ ${#VOLUME_ARCHIVES[@]} -eq 0 ] && [ ${#HOST_PATHS[@]} -eq 0 ]; then
    echo "[ERROR] No backup sources found. Nothing to do." >&2
    exit 1
fi

mkdir -p "${BACKUP_DIR}"

echo "Creating backup archive..."
echo "  Volume archives:"
for a in "${VOLUME_ARCHIVES[@]:-}"; do
    [ -n "${a:-}" ] && echo "    ${a}"
done
echo "  Host paths:"
for p in "${HOST_PATHS[@]:-}"; do
    [ -n "${p:-}" ] && echo "    ${p}"
done

# Reproducible tar (sorted names, zero mtime). Volume archives live in the
# staging dir; host paths are added relative to / so absolute paths reproduce
# on restore.
TAR_INPUTS=()
for a in "${VOLUME_ARCHIVES[@]:-}"; do
    [ -n "${a:-}" ] && TAR_INPUTS+=("${a}")
done
for p in "${HOST_PATHS[@]:-}"; do
    [ -n "${p:-}" ] && TAR_INPUTS+=("${p}")
done

tar --sort=name --mtime='@0' -czf "${ARCHIVE_BASE}" "${TAR_INPUTS[@]}"

echo "  Archive: ${ARCHIVE_BASE} ($(du -sh "${ARCHIVE_BASE}" | cut -f1))"

# -----------------------------------------------------------------------
# Encryption-at-rest
# -----------------------------------------------------------------------
ENCRYPTED_PATH=""

# Option 1: GPG
if command -v gpg >/dev/null 2>&1; then
    FIRST_KEY=$(gpg --list-secret-keys --with-colons 2>/dev/null \
        | awk -F: '/^sec/{print $5; exit}' || true)
    if [ -n "${FIRST_KEY}" ]; then
        echo "  Encrypting with GPG key: ${FIRST_KEY}..."
        ENCRYPTED_PATH="${ARCHIVE_BASE}.gpg"
        gpg --batch --yes --encrypt --recipient "${FIRST_KEY}" \
            --output "${ENCRYPTED_PATH}" "${ARCHIVE_BASE}"
        rm -f "${ARCHIVE_BASE}"
        echo "  Encrypted archive: ${ENCRYPTED_PATH}"
    fi
fi

# Option 2: age (if no GPG key)
if [ -z "${ENCRYPTED_PATH}" ] && command -v age >/dev/null 2>&1; then
    AGE_KEY_FILE="${HOME}/.config/devbox/age-key.pub"
    if [ -f "${AGE_KEY_FILE}" ]; then
        echo "  Encrypting with age key from ${AGE_KEY_FILE}..."
        ENCRYPTED_PATH="${ARCHIVE_BASE}.age"
        age --recipient-file "${AGE_KEY_FILE}" \
            --output "${ENCRYPTED_PATH}" "${ARCHIVE_BASE}"
        rm -f "${ARCHIVE_BASE}"
        echo "  Encrypted archive: ${ENCRYPTED_PATH}"
    else
        echo "  [WARN] age is installed but no key found at ${AGE_KEY_FILE}"
        echo "         Generate one: age-keygen -o ~/.config/devbox/age-key.txt"
        echo "         Then: grep ^Age-public-key ~/.config/devbox/age-key.txt > ${AGE_KEY_FILE}"
    fi
fi

# Option 3: Plaintext fallback (loud warning)
if [ -z "${ENCRYPTED_PATH}" ]; then
    echo ""
    echo "============================================================" >&2
    echo "  WARNING: BACKUP IS NOT ENCRYPTED                         " >&2
    echo "  Install GPG and generate a key, or install age.          " >&2
    echo "  The archive contains credentials and persistent data.    " >&2
    echo "  Archive: ${ARCHIVE_BASE}                                 " >&2
    echo "============================================================" >&2
    echo ""
    chmod 600 "${ARCHIVE_BASE}"
    echo "  Set archive permissions to 600 (plaintext - no encryption available)"
fi

echo ""
echo "[OK] Backup complete."
FINAL="${ENCRYPTED_PATH:-${ARCHIVE_BASE}}"
echo "  Final: ${FINAL}"
ls -lh "${FINAL}"
