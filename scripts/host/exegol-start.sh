#!/usr/bin/env bash
# Start Exegol using the official CLI with sensible defaults.
# Usage: ./exegol-start.sh [name] [--port PORT] [--vpn FILE] [--log] [--privileged]
#
# First run:  creates container with desktop (noVNC browser access)
# Resume:     re-enters existing container
#
# Desktop: http://exegol.internal:PORT/vnc.html
#   Password is randomly generated per-start and printed once below.
#
# NOTE: UFW rule added by this script is NOT auto-removed on container stop.
#       To remove it manually: sudo ufw delete allow in on tailscale0 to any port PORT proto tcp
#       See docs/exegol.md for the full cleanup procedure.
set -euo pipefail

NAME="exegol-htb"
PORT=45377
EXTRA_ARGS=()
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"; shift 2 ;;
        --vpn)
            EXTRA_ARGS+=("--vpn" "$2"); shift 2 ;;
        --log)
            EXTRA_ARGS+=("--log"); shift ;;
        --privileged)
            EXTRA_ARGS+=("--privileged"); shift ;;
        -*)
            echo "Unknown option: $1"
            echo "Usage: $0 [name] [--port PORT] [--vpn FILE] [--log] [--privileged]"
            exit 1 ;;
        *)
            POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done

[[ ${#POSITIONAL_ARGS[@]} -gt 0 ]] && NAME="${POSITIONAL_ARGS[0]}"
CONTAINER="exegol-${NAME}"

echo "Exegol: ${NAME}"

# -----------------------------------------------------------------------
# F1: Pre-flight Tailscale check
# -----------------------------------------------------------------------
if ! ip link show tailscale0 >/dev/null 2>&1; then
    echo "[ERROR] tailscale0 interface not found." >&2
    echo "        Ensure Tailscale is connected before starting Exegol noVNC." >&2
    echo "        Run: tailscale up" >&2
    exit 1
fi

# -----------------------------------------------------------------------
# Resume existing container (exegol CLI handles restart + desktop)
# -----------------------------------------------------------------------
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "   Resuming existing container..."
    exegol start "${NAME}"
    exit 0
fi

echo "   Image: free | Desktop port: ${PORT}"

# -----------------------------------------------------------------------
# F1: Open UFW for noVNC on tailscale0 only
# -----------------------------------------------------------------------
echo "   Opening UFW port ${PORT}/tcp on tailscale0..."
sudo ufw allow in on tailscale0 to any port "${PORT}" proto tcp \
    comment "exegol-novnc-${CONTAINER}"
echo "   NOTE: UFW rule is NOT auto-removed. See docs/exegol.md for cleanup."

# -----------------------------------------------------------------------
# F2: Generate a random VNC password (not hardcoded 'exegol')
# -----------------------------------------------------------------------
EXEGOL_PASS=$(openssl rand -base64 12)

echo ""

# Background job: wait for container to start, then set VNC password
(
    for _i in $(seq 1 60); do
        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
            sleep 3
            docker exec "${CONTAINER}" bash -c "echo 'root:${EXEGOL_PASS}' | chpasswd" 2>/dev/null
            printf '\n' >/dev/tty
            echo "========================================================" >/dev/tty
            echo "Desktop ready!" >/dev/tty
            echo "   URL:      http://exegol.internal:${PORT}/vnc.html" >/dev/tty
            echo "   User:     root" >/dev/tty
            # F2: print password ONCE
            echo "   Password: ${EXEGOL_PASS}" >/dev/tty
            echo "To rotate password: ~/docker/devbox/scripts/host/exegol-reset-vnc.sh ${CONTAINER}" >/dev/tty
            echo "========================================================" >/dev/tty
            break
        fi
        sleep 1
    done
) &

# desktop-config uses 0.0.0.0 — this is container-internal binding, do NOT change
exegol start "${NAME}" free --desktop --desktop-config "http:0.0.0.0:${PORT}" "${EXTRA_ARGS[@]}"
