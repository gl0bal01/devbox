# shellcheck shell=sh
# Installed by devbox setup.sh to /etc/profile.d/mise.sh: activates mise in
# every bash/zsh/sh login shell. Skipped for root, whose PATH stays clean.
if [ "$(id -u)" -ne 0 ] && command -v mise >/dev/null 2>&1; then
    case "${ZSH_VERSION:+zsh}${BASH_VERSION:+bash}" in
        zsh)  eval "$(mise activate zsh)" ;;
        bash) eval "$(mise activate bash)" ;;
        *)    eval "$(mise activate sh)" ;;
    esac
fi
