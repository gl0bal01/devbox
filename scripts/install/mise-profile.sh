# DevBox v3 — system-wide mise activation
# Installed by setup.sh into /etc/profile.d/mise.sh (sourced by every login shell).
# Source of truth: scripts/install/mise-profile.sh
# shellcheck shell=sh

# Pick the integration matching the current shell. /etc/profile.d is sourced
# by both bash and zsh login shells, but `mise activate bash` emits bash-only
# syntax that breaks under zsh.
if [ -z "$SUDO_USER" ] && command -v mise >/dev/null 2>&1; then
    case "${ZSH_VERSION:+zsh}${BASH_VERSION:+bash}" in
        zsh)  eval "$(mise activate zsh)" ;;
        bash) eval "$(mise activate bash)" ;;
        *)    eval "$(mise activate sh)" ;;
    esac
fi
