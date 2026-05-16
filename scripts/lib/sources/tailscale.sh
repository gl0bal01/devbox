#!/usr/bin/env bash
# Source handler: Tailscale install.sh
# Uses pkgs.tailscale.com stable JSON to find the current install script URL.
# Output: URL\tSHA256\n
set -euo pipefail

# Tailscale's stable channel install script — canonical URL
URL="https://tailscale.com/install.sh"

TMPFILE=$(mktemp /tmp/tailscale-verify.XXXXXX)
trap 'rm -f "${TMPFILE}"' EXIT INT TERM

curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 --output "${TMPFILE}" "${URL}"
SHA=$(sha256sum "${TMPFILE}" | awk '{print $1}')

printf '%s\t%s\n' "${URL}" "${SHA}"
