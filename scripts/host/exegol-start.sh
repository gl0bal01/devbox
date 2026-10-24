#!/usr/bin/env bash
# Start (or resume) an Exegol container with the noVNC desktop.
# Usage: exegol-start.sh [name] [--port PORT] [--vpn FILE] [--log] [--privileged]
#
# Desktop: http://exegol.internal:PORT/vnc.html, user root, random password
# printed once (rotate: exegol-reset-vnc.sh exegol-<name>). The workspace is
# ~/docker/exegol-workspace/<name>, which backup.sh archives. Exegol uses host
# networking, so the port is opened in UFW on tailscale0 only. The rule is
# not removed when the container stops:
#   sudo ufw delete allow in on tailscale0 to any port PORT proto tcp
set -euo pipefail

NAME="htb"
PORT=45377
EXTRA_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --port)       PORT="$2"; shift 2 ;;
        --vpn)        EXTRA_ARGS+=(--vpn "$2"); shift 2 ;;
        --log)        EXTRA_ARGS+=(--log); shift ;;
        --privileged) EXTRA_ARGS+=(--privileged); shift ;;
        -*)           echo "Usage: $0 [name] [--port PORT] [--vpn FILE] [--log] [--privileged]" >&2; exit 2 ;;
        *)            NAME="$1"; shift ;;
    esac
done
CONTAINER="exegol-${NAME}"
WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/exegol-workspace/${NAME}"

command -v exegol >/dev/null 2>&1 || { echo "exegol CLI not found: it is installed by setup.sh via mise (pypi:exegol)." >&2; exit 1; }
ip link show tailscale0 >/dev/null 2>&1 || { echo "tailscale0 not found: run 'sudo tailscale up' first." >&2; exit 1; }

sudo ufw allow in on tailscale0 to any port "${PORT}" proto tcp comment "exegol-novnc-${CONTAINER}" >/dev/null
if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
    exec exegol start "${NAME}"
fi
PASS=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9')

# Set the desktop password as soon as the container exists.
(
    for _ in $(seq 1 120); do
        if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
            sleep 3
            printf 'root:%s\n' "${PASS}" | docker exec -i "${CONTAINER}" chpasswd
            printf '\nDesktop: http://exegol.internal:%s/vnc.html  user: root  password: %s\n' "${PORT}" "${PASS}" >/dev/tty
            exit 0
        fi
        sleep 1
    done
) &

# Bound to all interfaces inside the host network namespace; UFW limits the
# port to tailscale0.
mkdir -p "${WORKSPACE}"
exegol start "${NAME}" free --workspace "${WORKSPACE}" --desktop --desktop-config "http:0.0.0.0:${PORT}" "${EXTRA_ARGS[@]}"
