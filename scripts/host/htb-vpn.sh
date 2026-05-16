#!/usr/bin/env bash
# Connect/disconnect/check HTB VPN using PID-file based process management.
# Usage: ./htb-vpn.sh [path/to/ovpn] [start|stop|status]
#
# F5: Uses --writepid /run/devbox/htb-vpn.pid instead of global pkill.
set -euo pipefail

OVPN_FILE="${1:-${HOME}/htb/lab.ovpn}"
ACTION="${2:-start}"

PID_DIR="/run/devbox"
PID_FILE="${PID_DIR}/htb-vpn.pid"
LOG_FILE="${PID_DIR}/htb-vpn.log"

# Escape a string for use as a regex literal (backslash-escape metachars)
escape_regex() {
    # shellcheck disable=SC2001
    echo "$1" | sed 's/[]\.^$*+?{}|()/\\&/g'
}

case "${ACTION}" in
    start)
        if [ ! -f "${OVPN_FILE}" ]; then
            echo "[ERROR] OVPN file not found: ${OVPN_FILE}" >&2
            echo ""
            echo "Usage: $0 /path/to/your.ovpn [start|stop|status]"
            echo ""
            echo "Available OVPN files in ~/htb:"
            ls -la "${HOME}/htb/"*.ovpn 2>/dev/null || echo "  (none found)"
            exit 1
        fi

        # Enforce restrictive permissions on OVPN file (may contain credentials)
        OVPN_PERMS=$(stat -c %a "${OVPN_FILE}" 2>/dev/null)
        if [ "${OVPN_PERMS}" != "600" ]; then
            echo "Securing OVPN file permissions (was ${OVPN_PERMS}, setting to 600)"
            chmod 600 "${OVPN_FILE}"
        fi

        # Ensure PID directory exists with correct ownership
        sudo install -d -m 0755 -o "${USER}" "${PID_DIR}"

        # Kill any stale PID-file process
        if [ -f "${PID_FILE}" ]; then
            OLD_PID=$(cat "${PID_FILE}")
            if kill -0 "${OLD_PID}" 2>/dev/null; then
                echo "Stopping existing VPN process (PID ${OLD_PID})..."
                sudo kill "${OLD_PID}" || true
                sleep 1
            fi
            sudo rm -f "${PID_FILE}"
        fi

        echo "Connecting to HTB VPN..."
        echo "   Config: ${OVPN_FILE}"
        echo "   Log:    ${LOG_FILE}"

        sudo openvpn \
            --config "${OVPN_FILE}" \
            --daemon \
            --writepid "${PID_FILE}" \
            --log "${LOG_FILE}"

        # Wait for tun0
        for _i in $(seq 1 10); do
            if ip addr show tun0 >/dev/null 2>&1; then
                echo ""
                echo "[OK] Connected!"
                ip addr show tun0 | grep -E "inet " | awk '{print "   VPN IP: "$2}'
                exit 0
            fi
            sleep 1
            printf '.'
        done

        echo ""
        echo "[ERROR] Connection may have failed. Check: tail -f ${LOG_FILE}" >&2
        exit 1
        ;;

    stop)
        echo "Disconnecting HTB VPN..."
        if [ -f "${PID_FILE}" ]; then
            VPID=$(cat "${PID_FILE}")
            if kill -0 "${VPID}" 2>/dev/null; then
                sudo kill "${VPID}"
                echo "[OK] Sent SIGTERM to PID ${VPID}"
            else
                echo "PID ${VPID} from pidfile is not running."
            fi
            sudo rm -f "${PID_FILE}"
        else
            echo "No PID file at ${PID_FILE}."
            # Fallback: regex-escaped pkill (avoid matching the calling script)
            ESCAPED=$(escape_regex "openvpn")
            if sudo pkill -f "^${ESCAPED}" 2>/dev/null; then
                echo "Killed openvpn process via pkill fallback."
            else
                echo "No openvpn process found."
            fi
        fi
        echo "[OK] Disconnected"
        ;;

    status)
        if ip addr show tun0 >/dev/null 2>&1; then
            echo "[OK] VPN Connected"
            ip addr show tun0 | grep -E "inet " | awk '{print "   VPN IP: "$2}'
            if [ -f "${PID_FILE}" ]; then
                echo "   PID: $(cat "${PID_FILE}")"
            fi
        else
            echo "[--] VPN Not Connected"
        fi
        ;;

    *)
        echo "Usage: $0 [ovpn-file] [start|stop|status]" >&2
        exit 1
        ;;
esac
