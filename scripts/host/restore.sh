#!/usr/bin/env bash
# Restore an archive made by backup.sh. Destructive: replaces the contents of
# the archived volumes and the archived secret/config files, then restarts
# the stack.
#
# Usage: restore.sh [--yes] <devbox-backup-*.tar[.age|.gpg]>
#   .age archives decrypt with ~/.config/devbox/age-identity.txt (or AGE_IDENTITY).
#
# Data comes from the archive; this host's configuration stays: the keys
# setup.sh manages (Tailscale IP, SSH port, HTTPS, GPU, compose chain, group)
# are kept, so restoring onto another server never rebinds or reconfigures it.
# Everything is validated before the stack is stopped.
set -euo pipefail
umask 077

export DEVBOX_HOME="${DEVBOX_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=../lib/devbox-contract.sh
. "${DEVBOX_HOME}/lib/devbox-contract.sh"
# shellcheck source=../lib/devbox-lib.sh
. "${DEVBOX_HOME}/lib/devbox-lib.sh"

YES=false
if [ "${1:-}" = --yes ]; then YES=true; shift; fi
ARCHIVE="${1:-}"
[ -f "${ARCHIVE}" ] || die "Usage: $0 [--yes] <devbox-backup-*.tar[.age|.gpg]>"

STAGING=$(mktemp -d)
trap 'rm -rf "${STAGING}"' EXIT
case "${ARCHIVE}" in
    *.age) age -d -i "${AGE_IDENTITY:-${DEVBOX_CONFIG_DIR}/age-identity.txt}" "${ARCHIVE}" | tar -C "${STAGING}" -xf - ;;
    *.gpg) gpg --batch -d "${ARCHIVE}" | tar -C "${STAGING}" -xf - ;;
    *)     tar -C "${STAGING}" -xf "${ARCHIVE}" ;;
esac

# --- validate everything before touching the running stack ------------------
[ -f "${STAGING}/MANIFEST" ] || die "${ARCHIVE} is not a devbox backup (no MANIFEST)."
[ -f "${STAGING}/files.tgz" ] && tar -tzf "${STAGING}/files.tgz" >/dev/null || die "files.tgz missing or corrupt in ${ARCHIVE}."
read -r -a VOLUMES <<<"$(sed -n 's/^volumes=//p' "${STAGING}/MANIFEST")"
for vol in "${VOLUMES[@]}"; do
    tar -tzf "${STAGING}/volumes/${vol}.tgz" >/dev/null 2>&1 || die "volumes/${vol}.tgz missing or corrupt in ${ARCHIVE}."
done

echo "Archive:  $(sed -n 's/^created=//p' "${STAGING}/MANIFEST") from $(sed -n 's/^host=//p' "${STAGING}/MANIFEST")"
echo "Volumes:  ${VOLUMES[*]:-none}"
echo "Files:    $(tar -tzf "${STAGING}/files.tgz" | grep -vc '/$') under ${DEVBOX_OWNER_HOME}"
if ! ${YES}; then
    read -r -p "This overwrites current data. Continue? [y/N] " reply
    [[ "${reply}" =~ ^[Yy]$ ]] || exit 0
fi

# Host-specific keys (file KEY...) that must survive the restore.
HOST_KEYS=(
    "${DEVBOX_CONFIG} DEVBOX_USER SSH_PORT ENABLE_HTTPS DOMAIN ACME_EMAIL GPU TAILSCALE_IP"
    "${DEVBOX_HOME}/traefik/.env COMPOSE_FILE TAILSCALE_IP DEVBOX_GID TRAEFIK_CONFIG_HASH"
    "${DEVBOX_HOME}/ollama-openwebui/.env COMPOSE_FILE DOMAIN"
)
saved="${STAGING}/host-keys"
: >"${saved}"
for entry in "${HOST_KEYS[@]}"; do
    read -r file keys <<<"${entry}"
    for k in ${keys}; do
        if [ -f "${file}" ] && grep -q "^${k}=" "${file}"; then
            printf '%s\t%s\t%s\n' "${file}" "${k}" "$(env_get "${file}" "${k}")" >>"${saved}"
        fi
    done
done

# --- restore -----------------------------------------------------------------
"${DEVBOX_HOME}/stop-all.sh"

# Exegol writes root-owned files the operator cannot overwrite: restore that
# part separately and do not let it block the critical files and volumes.
tar -C "${DEVBOX_OWNER_HOME}" -xzf "${STAGING}/files.tgz" --exclude='docker/exegol-workspace'
if tar -tzf "${STAGING}/files.tgz" | grep -q '^docker/exegol-workspace/.'; then
    tar -C "${DEVBOX_OWNER_HOME}" -xzf "${STAGING}/files.tgz" --wildcards 'docker/exegol-workspace/*' \
        || warn "Some Exegol workspace files were not restored (root-owned). Re-run that part with sudo: sudo tar -C ${DEVBOX_OWNER_HOME} -xzf <files.tgz from the archive> docker/exegol-workspace"
fi
while IFS=$'\t' read -r file key value; do
    env_set "${file}" "${key}" "${value}"
done <"${saved}"

# The htpasswd middlewares derive from the restored credentials.
render_basic_auth dashboard-auth "${DEVBOX_SECRETS_DIR}/traefik-dashboard.txt" "${DEVBOX_HOME}/traefik/dynamic/dashboard-auth.yml"
render_basic_auth ollama-auth "${DEVBOX_SECRETS_DIR}/ollama-auth.txt" "${DEVBOX_HOME}/traefik/dynamic/ollama-auth.yml"

# Create containers and labelled volumes without starting anything.
for svc in "${DEVBOX_SERVICES[@]}"; do
    ( cd "${DEVBOX_HOME}/${svc}" && docker compose up --no-start --quiet-pull )
done

skipped=()
for vol in "${VOLUMES[@]}"; do
    c=$(docker ps -aq --filter "volume=${vol}" | head -n1)
    if [ -z "${c}" ]; then
        # e.g. traefik_letsencrypt from an HTTPS-era archive on an HTTP host.
        skipped+=("${vol}")
        continue
    fi
    docker run --rm --network none --user 0:0 --entrypoint sh \
        -v "${vol}:/data" -v "${STAGING}/volumes:/backup:ro" "$(docker inspect -f '{{.Image}}' "${c}")" \
        -c "find /data -mindepth 1 -delete && tar -xzf '/backup/${vol}.tgz' -C /data"
    echo "  restored ${vol}"
done

"${DEVBOX_HOME}/start-all.sh"
if [ ${#skipped[@]} -gt 0 ]; then
    warn "Not used by this host's stack, left in the archive: ${skipped[*]}"
fi
if [ -s "${STAGING}/ollama-models.txt" ]; then
    echo ""
    echo "Ollama models are not in backups. Re-pull with:"
    awk 'NR > 1 { print "  docker exec ollama ollama pull " $1 }' "${STAGING}/ollama-models.txt"
fi
log "Restore complete."
