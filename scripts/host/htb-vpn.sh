#!/usr/bin/env bash
# Connect, disconnect or check the HTB/THM OpenVPN tunnel.
# Usage: htb-vpn.sh [path/to/lab.ovpn] [start|stop|status]
#        htb-vpn.sh stop|status
#
# The daemon is tracked through a PID file in /run/devbox (created at boot by
# /etc/tmpfiles.d/devbox.conf); `stop` signals only that process, and only if
# it is openvpn. setup.sh allows `sudo openvpn` and
# `sudo pkill -F /run/devbox/htb-vpn.pid openvpn` without a password.
set -euo pipefail

case "${1:-}" in
    start|stop|status) ACTION="$1"; OVPN_FILE="${2:-${HOME}/htb/lab.ovpn}" ;;
    *)                 OVPN_FILE="${1:-${HOME}/htb/lab.ovpn}"; ACTION="${2:-start}" ;;
esac
PID_DIR="${DEVBOX_RUN_DIR:-/run/devbox}"
PID_FILE="${PID_DIR}/htb-vpn.pid"
LOG_FILE="${PID_DIR}/htb-vpn.log"
TUN_WAIT="${HTB_VPN_TUN_WAIT:-10}"

running_pid() { [ -f "${PID_FILE}" ] && pgrep -F "${PID_FILE}" openvpn; }
stop_tunnel() { sudo pkill -F "${PID_FILE}" openvpn; }

case "${ACTION}" in
    start)
        if [ ! -f "${OVPN_FILE}" ]; then
            echo "OVPN file not found: ${OVPN_FILE}" >&2
            ls "${HOME}"/htb/*.ovpn 2>/dev/null | sed 's/^/  /' >&2 || true
            exit 1
        fi
        [ -d "${PID_DIR}" ] || { echo "${PID_DIR} missing: re-run setup.sh (tmpfiles.d/devbox.conf)." >&2; exit 1; }
        chmod 600 "${OVPN_FILE}"
        if pid=$(running_pid); then
            echo "Stopping previous tunnel (PID ${pid})"
            stop_tunnel
            sleep 1
        fi
        rm -f "${PID_FILE}"
        sudo openvpn --config "${OVPN_FILE}" --daemon --writepid "${PID_FILE}" --log "${LOG_FILE}"
        for _ in $(seq 1 "${TUN_WAIT}"); do
            if ip -4 addr show tun0 >/dev/null 2>&1; then
                ip -4 -o addr show tun0 | awk '{print "[ok] Connected, VPN IP " $4}'
                exit 0
            fi
            sleep 1
        done
        echo "No tun0 after ${TUN_WAIT}s. Log: ${LOG_FILE}" >&2
        exit 1
        ;;
    stop)
        if pid=$(running_pid); then
            stop_tunnel
            echo "[ok] Stopped PID ${pid}"
        else
            echo "Not running."
        fi
        rm -f "${PID_FILE}"
        ;;
    status)
        if ip -4 addr show tun0 >/dev/null 2>&1; then
            ip -4 -o addr show tun0 | awk '{print "[ok] Connected, VPN IP " $4}'
            if pid=$(running_pid); then echo "     PID ${pid}"; fi
        else
            echo "Not connected."
        fi
        ;;
    *)
        echo "Usage: $0 [ovpn-file] [start|stop|status]" >&2
        exit 2
        ;;
esac
