#!/usr/bin/env bash
# Rotate the noVNC (root) password of a running Exegol container.
# Usage: exegol-reset-vnc.sh <container-name>
set -euo pipefail

CONTAINER="${1:-}"
if [ -z "${CONTAINER}" ] || ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
    echo "Usage: $0 <running-container>   (e.g. exegol-htb)" >&2
    docker ps --format '  {{.Names}}' | grep exegol- >&2 || true
    exit 1
fi

PASS=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9')
# Password goes through stdin: never on a command line visible in ps.
printf 'root:%s\n' "${PASS}" | docker exec -i "${CONTAINER}" chpasswd
echo "New noVNC password for ${CONTAINER} (user root): ${PASS}"
