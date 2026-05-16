#!/usr/bin/env bash
# Rotate the VNC/noVNC password for a running Exegol container.
# Usage: exegol-reset-vnc.sh <container-name>
#
# Prints the new password once to stdout.
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <container-name>" >&2
    echo "Example: $0 exegol-htb" >&2
    exit 1
fi

CONTAINER="$1"

# Verify container exists and is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "[ERROR] Container '${CONTAINER}' is not running." >&2
    echo "        Running containers:" >&2
    docker ps --format '  {{.Names}}' >&2
    exit 1
fi

PASS=$(openssl rand -base64 12)

docker exec "${CONTAINER}" bash -c "echo 'root:${PASS}' | chpasswd"

echo ""
echo "VNC password rotated for container: ${CONTAINER}"
echo "  New password: ${PASS}"
echo ""
echo "Use this password at the noVNC login prompt."
