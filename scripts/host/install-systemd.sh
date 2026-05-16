#!/usr/bin/env bash
# =============================================================================
# install-systemd.sh — Render and install devbox systemd units
# =============================================================================
# Renders devbox.service, devbox-backup.service, and devbox-backup.timer from
# templates in ${DEVBOX_HOME}/systemd/ using envsubst, writes them to
# /etc/systemd/system/, then enables devbox.service + devbox-backup.timer.
#
# The service is NOT started automatically. Operator decides when to start:
#   sudo systemctl start devbox.service
#   sudo systemctl list-timers devbox-backup.timer
#
# Requires root (runs as part of post-install hardening).
# =============================================================================
set -euo pipefail

# Root guard.
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] install-systemd.sh must be run as root (sudo)." >&2
    exit 1
fi

# Locate the installed runtime contract.
DEVBOX_HOME="${DEVBOX_HOME:-${HOME}/docker}"
CONTRACT="${DEVBOX_HOME}/lib/devbox-contract.sh"

if [ ! -f "${CONTRACT}" ]; then
    echo "[ERROR] Missing ${CONTRACT}." >&2
    echo "        Run setup.sh to install the runtime contract first." >&2
    exit 1
fi
# shellcheck disable=SC1090
. "${CONTRACT}"

# Resolve DEVBOX_USER from the install-level config.env (written by setup.sh
# with the operator's real account). The contract default ("dev" or whatever
# the contract resolved at install time) acts as the final fallback.
CONFIG_ENV="${SUDO_USER:+/home/${SUDO_USER}}/.config/devbox/config.env"
[ -z "${SUDO_USER:-}" ] && CONFIG_ENV="${HOME}/.config/devbox/config.env"
if [ -f "${CONFIG_ENV}" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${CONFIG_ENV}"
    set +a
fi

TEMPLATE_DIR="${DEVBOX_HOME}/systemd"
SYSTEMD_DIR="/etc/systemd/system"

if [ ! -d "${TEMPLATE_DIR}" ]; then
    echo "[ERROR] Template directory not found: ${TEMPLATE_DIR}" >&2
    echo "        Re-run setup.sh to sync the systemd templates." >&2
    exit 1
fi

echo "=== devbox systemd install ==="
echo "  DEVBOX_HOME : ${DEVBOX_HOME}"
echo "  DEVBOX_USER : ${DEVBOX_USER}"
echo "  templates   : ${TEMPLATE_DIR}"
echo "  target dir  : ${SYSTEMD_DIR}"
echo ""

# Render each template with only DEVBOX_USER and DEVBOX_HOME substituted.
for tmpl in \
    devbox.service.template \
    devbox-backup.service.template \
    devbox-backup.timer.template; do

    src="${TEMPLATE_DIR}/${tmpl}"
    # Strip the trailing .template suffix to get the unit name.
    unit="${SYSTEMD_DIR}/${tmpl%.template}"

    if [ ! -f "${src}" ]; then
        echo "[ERROR] Template missing: ${src}" >&2
        exit 1
    fi

    # envsubst with an explicit variable allowlist prevents accidental
    # expansion of other shell variables present in the template body.
    envsubst '$DEVBOX_USER $DEVBOX_HOME' <"${src}" >"${unit}"
    chmod 0644 "${unit}"
    echo "  [OK] rendered ${tmpl%.template} -> ${unit}"
done

echo ""
echo "Reloading systemd daemon..."
systemctl daemon-reload
echo "  [OK] daemon-reload"

echo ""
echo "Enabling units..."
systemctl enable devbox.service
echo "  [OK] devbox.service enabled"
systemctl enable devbox-backup.timer
echo "  [OK] devbox-backup.timer enabled"

echo ""
echo "=== Next steps ==="
echo "  Start the stack:"
echo "    sudo systemctl start devbox.service"
echo ""
echo "  Verify the backup timer:"
echo "    sudo systemctl list-timers devbox-backup.timer"
echo ""
echo "  Check service status:"
echo "    sudo systemctl status devbox.service"
