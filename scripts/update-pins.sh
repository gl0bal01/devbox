#!/usr/bin/env bash
# Check or refresh the trust anchors in scripts/lib/pins.sh.
#
#   --check  exit 1 if a vendor key no longer carries its pinned fingerprint
#            (key rotation: verify the new key out of band, then edit
#            pins.sh) or if the Oh My Zsh pin is behind upstream
#   --apply  move the Oh My Zsh pin to upstream HEAD; key fingerprints are
#            never changed automatically
#
# Queries the network: run by the monthly refresh job, not by PR CI.
set -euo pipefail

DEVBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINS="${DEVBOX_DIR}/scripts/lib/pins.sh"
# shellcheck source=lib/pins.sh
. "${PINS}"
# shellcheck source=lib/devbox-lib.sh
. "${DEVBOX_DIR}/scripts/lib/devbox-lib.sh"

case "${1:-}" in
    --check) MODE=check ;;
    --apply) MODE=apply ;;
    *) echo "Usage: $0 --check|--apply" >&2; exit 2 ;;
esac

rc=0
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

check_key() {
    local name="$1" url="$2" fpr="$3"
    curl -fsSL --proto '=https' "${url}" -o "${tmp}/${name}.key"
    if gpg_export_pinned "${tmp}/${name}.key" "${fpr}" "${tmp}/${name}.gpg"; then
        echo "[ok]    ${name} key ${fpr}"
    else
        echo "[drift] ${name} key at ${url} no longer carries ${fpr}" >&2
        rc=1
    fi
}
check_key tailscale "${TAILSCALE_APT_URL}/noble.noarmor.gpg" "${TAILSCALE_APT_KEY_FPR}"
check_key mise "${MISE_APT_KEY_URL}" "${MISE_APT_KEY_FPR}"

head=$(git ls-remote "${OHMYZSH_REPO}" HEAD | cut -f1)
if [ "${head}" = "${OHMYZSH_COMMIT}" ]; then
    echo "[ok]    oh-my-zsh ${OHMYZSH_COMMIT}"
elif [ "${MODE}" = apply ]; then
    sed -i "s/^OHMYZSH_COMMIT=.*/OHMYZSH_COMMIT=\"${head}\"/" "${PINS}"
    echo "[new]   oh-my-zsh ${OHMYZSH_COMMIT} -> ${head}"
else
    echo "[drift] oh-my-zsh ${OHMYZSH_COMMIT} -> ${head}"
    rc=1
fi
exit "${rc}"
