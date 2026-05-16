#!/usr/bin/env bash
# Source handler: lazydocker — linux x86_64 tar.gz
# Output: URL\tSHA256\n
set -euo pipefail

API="https://api.github.com/repos/jesseduffield/lazydocker/releases/latest"

TAG=$(curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 "${API}" \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

if [ -z "${TAG}" ]; then
    echo "[ERROR] Could not determine lazydocker latest tag" >&2
    exit 1
fi

VERSION="${TAG#v}"
URL="https://github.com/jesseduffield/lazydocker/releases/download/${TAG}/lazydocker_${VERSION}_Linux_x86_64.tar.gz"

TMPFILE=$(mktemp /tmp/lazydocker-verify.XXXXXX)
trap 'rm -f "${TMPFILE}"' EXIT INT TERM

curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 --output "${TMPFILE}" "${URL}"
SHA=$(sha256sum "${TMPFILE}" | awk '{print $1}')

printf '%s\t%s\n' "${URL}" "${SHA}"
