# DevBox v3 — system-wide mise activation
# Installed by setup.sh into /etc/profile.d/mise.sh (sourced by every login shell).
# Source of truth: scripts/install/mise-profile.sh
# shellcheck shell=sh

if [ -z "$SUDO_USER" ] && command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash)"
fi
