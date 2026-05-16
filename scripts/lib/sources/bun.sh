#!/usr/bin/env bash
# Source handler: bun (Oven) — linux-x64 zip
# Output: URL\tSHA256\n
set -euo pipefail

API="https://api.github.com/repos/oven-sh/bun/releases/latest"

TAG=$(curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 "${API}" \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

if [ -z "${TAG}" ]; then
    echo "[ERROR] Could not determine bun latest tag" >&2
    exit 1
fi

# Strip leading 'bun-' prefix for the version component in the URL
# VERSION extracted for documentation; URL uses TAG directly
# shellcheck disable=SC2034
VERSION="${TAG#bun-}"
URL="https://github.com/oven-sh/bun/releases/download/${TAG}/bun-linux-x64.zip"

TMPFILE=$(mktemp /tmp/bun-verify.XXXXXX)
trap 'rm -f "${TMPFILE}"' EXIT INT TERM

curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 --output "${TMPFILE}" "${URL}"
SHA=$(sha256sum "${TMPFILE}" | awk '{print $1}')

printf '%s\t%s\n' "${URL}" "${SHA}"
