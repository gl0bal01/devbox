#!/usr/bin/env bash
# Refresh scripts/lib/download-manifest.sh by querying each source handler.
#
# Usage:
#   ./scripts/update-manifest.sh --check    # diff only, exit 1 on drift
#   ./scripts/update-manifest.sh --apply    # write stabilized manifest
#   ./scripts/update-manifest.sh --apply --force  # apply even if git is dirty
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCES_DIR="${SCRIPT_DIR}/lib/sources"
MANIFEST="${SCRIPT_DIR}/lib/download-manifest.sh"

MODE=""
FORCE=false

for arg in "$@"; do
    case "${arg}" in
        --check) MODE="check" ;;
        --apply) MODE="apply" ;;
        --force) FORCE=true ;;
        *) echo "Unknown argument: ${arg}" >&2; exit 1 ;;
    esac
done

if [ -z "${MODE}" ]; then
    echo "Usage: $0 [--check|--apply] [--force]" >&2
    exit 1
fi

# Guard: refuse --apply on dirty manifest unless --force
if [ "${MODE}" = "apply" ] && [ "${FORCE}" = "false" ]; then
    if ! git -C "${SCRIPT_DIR}" diff --quiet --exit-code "${MANIFEST}" 2>/dev/null; then
        echo "[ERROR] ${MANIFEST} has uncommitted changes. Use --force to override." >&2
        exit 1
    fi
fi

echo "Querying source handlers..."

# Map: source handler name -> manifest variable name prefix
declare -A NAME_MAP
NAME_MAP=(
    [tailscale]=TAILSCALE
    [lazygit]=LAZYGIT
    [lazydocker]=LAZYDOCKER
    [neovim]=NEOVIM
    [rustup]=RUSTUP
    [bun]=BUN
    [claude]=CLAUDE
    [opencode]=OPENCODE
    [goose]=GOOSE
    [fabric]=FABRIC
)

declare -A RESOLVED_URL
declare -A RESOLVED_SHA

for handler in "${SOURCES_DIR}"/*.sh; do
    name=$(basename "${handler}" .sh)
    varname="${NAME_MAP[${name}]:-}"
    if [ -z "${varname}" ]; then
        echo "  [SKIP] ${name}.sh (no manifest mapping)"
        continue
    fi
    echo "  -> ${name}..."
    result=$(bash "${handler}" 2>/dev/null) || {
        echo "  [WARN] ${name}.sh failed — keeping __PLACEHOLDER__"
        continue
    }
    url=$(printf '%s' "${result}" | cut -f1)
    sha=$(printf '%s' "${result}" | cut -f2)
    RESOLVED_URL["${varname}"]="${url}"
    RESOLVED_SHA["${varname}"]="${sha}"
    echo "     URL: ${url}"
    echo "     SHA: ${sha}"
done

# Build the new manifest by rewriting the current one
TMPMANIFEST="${MANIFEST}.tmp.$$"
trap 'rm -f "${TMPMANIFEST}"' EXIT INT TERM

cp "${MANIFEST}" "${TMPMANIFEST}"

# Apply resolved values into the tmp manifest
for varname in "${!RESOLVED_URL[@]}"; do
    url="${RESOLVED_URL[${varname}]}"
    sha="${RESOLVED_SHA[${varname}]}"
    # Replace URL line
    sed -i "s|^MANIFEST_${varname}_URL=.*|MANIFEST_${varname}_URL=\"${url}\"|" "${TMPMANIFEST}"
    # Replace SHA line
    sed -i "s|^MANIFEST_${varname}_SHA=.*|MANIFEST_${varname}_SHA=\"${sha}\"|" "${TMPMANIFEST}"
done

if [ "${MODE}" = "check" ]; then
    if diff -u "${MANIFEST}" "${TMPMANIFEST}"; then
        echo ""
        echo "[OK] Manifest is up to date."
        exit 0
    else
        echo ""
        echo "[DRIFT] Manifest has changed. Run --apply to update." >&2
        exit 1
    fi
fi

# --apply
mv "${TMPMANIFEST}" "${MANIFEST}"
trap - EXIT INT TERM
echo ""
echo "[OK] Manifest updated: ${MANIFEST}"
