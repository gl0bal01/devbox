#!/usr/bin/env bash
# Source handler: Neovim — linux x86_64 tar.gz
# Output: URL\tSHA256\n
set -euo pipefail

API="https://api.github.com/repos/neovim/neovim/releases/latest"

TAG=$(curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 "${API}" \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

if [ -z "${TAG}" ]; then
    echo "[ERROR] Could not determine neovim latest tag" >&2
    exit 1
fi

URL="https://github.com/neovim/neovim/releases/download/${TAG}/nvim-linux-x86_64.tar.gz"

TMPFILE=$(mktemp /tmp/neovim-verify.XXXXXX)
trap 'rm -f "${TMPFILE}"' EXIT INT TERM

curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 --output "${TMPFILE}" "${URL}"
SHA=$(sha256sum "${TMPFILE}" | awk '{print $1}')

printf '%s\t%s\n' "${URL}" "${SHA}"
