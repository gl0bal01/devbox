#!/usr/bin/env bash
# Source handler: rustup install script
# Reads https://static.rust-lang.org/rustup/release-stable.toml to get latest version.
# Output: URL\tSHA256\n
set -euo pipefail

TOML_URL="https://static.rust-lang.org/rustup/release-stable.toml"

TOML=$(curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 "${TOML_URL}")

VERSION=$(printf '%s' "${TOML}" | awk -F'"' '/^version/{print $2; exit}')

if [ -z "${VERSION}" ]; then
    echo "[ERROR] Could not parse rustup version from ${TOML_URL}" >&2
    exit 1
fi

URL="https://static.rust-lang.org/rustup/archive/${VERSION}/x86_64-unknown-linux-gnu/rustup-init"

TMPFILE=$(mktemp /tmp/rustup-verify.XXXXXX)
trap 'rm -f "${TMPFILE}"' EXIT INT TERM

curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 --output "${TMPFILE}" "${URL}"
SHA=$(sha256sum "${TMPFILE}" | awk '{print $1}')

printf '%s\t%s\n' "${URL}" "${SHA}"
