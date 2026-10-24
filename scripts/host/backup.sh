#!/usr/bin/env bash
# Back up devbox state into one archive under ~/.local/share/devbox/backups/.
#
# Archive layout (tar):
#   MANIFEST               created, contract version, volumes
#   volumes/<volume>.tgz   every Compose volume of every service, except the
#                          re-pullable ones in DEVBOX_BACKUP_EXCLUDE_VOLUMES
#   files.tgz              DEVBOX_BACKUP_PATHS + each service .env, relative
#                          to the owner's home
#   ollama-models.txt      `ollama list`, to re-pull models after a restore
#
# Containers using a volume are paused while it is archived, so databases
# (Open WebUI's SQLite) are captured crash-consistent.
#
# Encryption (first match): age recipients in ~/.config/devbox/age-recipients.txt,
# or BACKUP_GPG_RECIPIENT in config.env. Otherwise the archive is plaintext
# (mode 0600) and a warning is printed. Keeps the newest DEVBOX_BACKUP_KEEP
# archives (default 14). Restore with restore.sh.
set -euo pipefail
umask 077

export DEVBOX_HOME="${DEVBOX_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=../lib/devbox-contract.sh
. "${DEVBOX_HOME}/lib/devbox-contract.sh"

KEEP="${DEVBOX_BACKUP_KEEP:-14}"
[[ "${KEEP}" =~ ^[1-9][0-9]*$ ]] || { echo "DEVBOX_BACKUP_KEEP must be >= 1" >&2; exit 2; }
docker info >/dev/null || { echo "Docker is not reachable: nothing backed up." >&2; exit 1; }
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
ARCHIVE="${DEVBOX_BACKUP_DIR}/devbox-backup-${STAMP}.tar"

mkdir -p "${DEVBOX_BACKUP_DIR}"
STAGING=$(mktemp -d "${DEVBOX_BACKUP_DIR}/.staging-XXXXXX")
PAUSED=()
OUT=""
cleanup() {
    local c
    for c in "${PAUSED[@]}"; do docker unpause "${c}" >/dev/null 2>&1 || true; done
    rm -rf "${STAGING}"
    [ -z "${OUT}" ] || rm -f "${OUT}.partial"
}
trap cleanup EXIT
mkdir -p "${STAGING}/volumes"

# tar_image <service> <volume> — an image already trusted by the stack that
# ships GNU tar: the one a container using the volume runs, else the
# service's first locked image.
tar_image() {
    local c
    c=$(docker ps -aq --filter "volume=$2" | head -n1)
    if [ -n "${c}" ]; then
        docker inspect -f '{{.Image}}' "${c}"
    else
        ( cd "${DEVBOX_HOME}/$1" && docker compose config --images | head -n1 )
    fi
}

BACKED_UP=()
for svc in "${DEVBOX_SERVICES[@]}"; do
    vols=$(docker volume ls -q --filter "label=com.docker.compose.project=${svc}")
    for vol in ${vols}; do
        key=$(docker volume inspect -f '{{index .Labels "com.docker.compose.volume"}}' "${vol}")
        if [[ " ${DEVBOX_BACKUP_EXCLUDE_VOLUMES} " == *" ${key} "* ]]; then
            echo "  skip   ${vol} (excluded: re-pullable)"
            continue
        fi
        image=$(tar_image "${svc}" "${vol}")
        mapfile -t users < <(docker ps -q --filter "volume=${vol}")
        for c in "${users[@]}"; do docker pause "${c}" >/dev/null && PAUSED+=("${c}"); done
        docker run --rm --network none --user 0:0 --entrypoint sh \
            -v "${vol}:/data:ro" -v "${STAGING}/volumes:/backup" "${image}" \
            -c "tar -czf '/backup/${vol}.tgz' -C /data . && chown $(id -u):$(id -g) '/backup/${vol}.tgz'"
        for c in "${PAUSED[@]}"; do docker unpause "${c}" >/dev/null; done
        PAUSED=()
        BACKED_UP+=("${vol}")
        echo "  volume ${vol}"
    done
done

paths=()
for p in ${DEVBOX_BACKUP_PATHS}; do
    [ -e "${DEVBOX_OWNER_HOME}/${p}" ] && paths+=("${p}")
done
for svc in "${DEVBOX_SERVICES[@]}"; do
    [ -f "${DEVBOX_HOME}/${svc}/.env" ] && paths+=("${DEVBOX_HOME#"${DEVBOX_OWNER_HOME}/"}/${svc}/.env")
done
tar -C "${DEVBOX_OWNER_HOME}" --ignore-failed-read -czf "${STAGING}/files.tgz" "${paths[@]}"
echo "  files  ${paths[*]}"

if docker ps --format '{{.Names}}' | grep -qx ollama; then
    docker exec ollama ollama list >"${STAGING}/ollama-models.txt" || true
fi

cat >"${STAGING}/MANIFEST" <<MANIFEST
created=${STAMP}
host=$(hostname)
contract=${DEVBOX_CONTRACT_VERSION}
volumes=${BACKED_UP[*]}
MANIFEST

# Encrypt while streaming: a plaintext copy never touches the disk when
# encryption is configured, and a failure leaves only a .partial (removed).
AGE_RECIPIENTS="${DEVBOX_CONFIG_DIR}/age-recipients.txt"
GPG_RECIPIENT="$(devbox_config_get BACKUP_GPG_RECIPIENT)"
if [ -s "${AGE_RECIPIENTS}" ]; then
    OUT="${ARCHIVE}.age"
    tar -C "${STAGING}" -cf - . | age -R "${AGE_RECIPIENTS}" -o "${OUT}.partial"
elif [ -n "${GPG_RECIPIENT}" ]; then
    OUT="${ARCHIVE}.gpg"
    tar -C "${STAGING}" -cf - . | gpg --batch --yes --trust-model always -r "${GPG_RECIPIENT}" -o "${OUT}.partial" -e
else
    OUT="${ARCHIVE}"
    tar -C "${STAGING}" -cf "${OUT}.partial" .
    echo "WARNING: backup is NOT encrypted (it contains credentials). Add age recipients to ${AGE_RECIPIENTS}." >&2
fi
chmod 0600 "${OUT}.partial"
mv "${OUT}.partial" "${OUT}"

# Retention over finished archives only; timestamps sort lexically.
mapfile -t old < <(find "${DEVBOX_BACKUP_DIR}" -maxdepth 1 -regextype posix-extended \
    -regex '.*/devbox-backup-[0-9TZ]+\.tar(\.age|\.gpg)?' -printf '%f\n' | sort -r | tail -n "+$(( KEEP + 1 ))")
for f in "${old[@]}"; do rm -f "${DEVBOX_BACKUP_DIR:?}/${f}"; done

echo "[ok] ${OUT} ($(du -h "${OUT}" | cut -f1))"
