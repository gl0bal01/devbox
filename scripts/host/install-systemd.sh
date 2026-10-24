#!/usr/bin/env bash
# Install devbox.service (start the stack at boot) and devbox-backup.timer
# (daily backup.sh) from the templates in ${DEVBOX_HOME}/systemd/.
# Run as root: sudo ~/docker/install-systemd.sh
# Units are enabled, not started: sudo systemctl start devbox.service
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }

# Resolve from this script's location: under sudo, HOME is /root.
export DEVBOX_HOME="${DEVBOX_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
[ -f "${DEVBOX_HOME}/lib/devbox-contract.sh" ] || { echo "No devbox install at ${DEVBOX_HOME}" >&2; exit 1; }
DEVBOX_USER="$(stat -c %U "${DEVBOX_HOME}")"
export DEVBOX_USER

for unit in devbox.service devbox-backup.service devbox-backup.timer; do
    envsubst '$DEVBOX_USER $DEVBOX_HOME' <"${DEVBOX_HOME}/systemd/${unit}.template" >"/etc/systemd/system/${unit}"
    chmod 0644 "/etc/systemd/system/${unit}"
    echo "  installed /etc/systemd/system/${unit}"
done
systemd-analyze verify /etc/systemd/system/devbox.service /etc/systemd/system/devbox-backup.service \
    /etc/systemd/system/devbox-backup.timer || echo "[warn] systemd-analyze verify reported problems (above)." >&2
systemctl daemon-reload
systemctl enable devbox.service devbox-backup.timer
echo "[ok] Enabled for ${DEVBOX_USER}. Start now: sudo systemctl start devbox.service"
