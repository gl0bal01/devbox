#!/usr/bin/env bash
# Source handler: Fabric (Daniel Miessler's AI framework) install script.
# Pinned-by-snapshot: fetches the CURRENT state of the installer and computes its SHA256.
# To update the pin, re-run scripts/update-manifest.sh --apply.
# Output: URL\tSHA256\n
set -euo pipefail

URL="https://raw.githubusercontent.com/danielmiessler/fabric/main/install.sh"

TMPFILE=$(mktemp /tmp/fabric-verify.XXXXXX)
trap 'rm -f "${TMPFILE}"' EXIT INT TERM

curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 --output "${TMPFILE}" "${URL}"
SHA=$(sha256sum "${TMPFILE}" | awk '{print $1}')

printf '%s\t%s\n' "${URL}" "${SHA}"
