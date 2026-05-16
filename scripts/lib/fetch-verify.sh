#!/usr/bin/env bash
# Sourcable library providing fetch_and_verify.
# Source this file, then call: fetch_and_verify <url> <expected_sha256> <destination_path>
#
# Emergency override: DEVBOX_ALLOW_UNVERIFIED=1 skips hash check (logs loudly).
#
# Design:
#   - Downloads to <dest>.tmp.<PID> in the SAME directory as <dest> (avoids
#     cross-filesystem moves and /tmp TOCTOU gaps per Critic gap analysis).
#   - Atomic mv after hash validation.
#   - Trap cleans up tempfile on EXIT/INT/TERM.

# Guard against double-sourcing
if [ -n "${_FETCH_VERIFY_LOADED:-}" ]; then
    return 0
fi
_FETCH_VERIFY_LOADED=1

fetch_and_verify() {
    local url="$1"
    local expected_sha256="$2"
    local dest="$3"

    if [ -z "${url}" ] || [ -z "${expected_sha256}" ] || [ -z "${dest}" ]; then
        echo "[fetch_and_verify] Usage: fetch_and_verify <url> <expected_sha256> <dest>" >&2
        return 1
    fi

    local dest_dir
    dest_dir="$(dirname "${dest}")"
    local tmpfile="${dest}.tmp.$$"

    # Cleanup trap registered for this function's scope
    # SC2317: _fv_cleanup is called indirectly via trap — not unreachable
    # shellcheck disable=SC2317
    _fv_cleanup() {
        rm -f "${tmpfile}" 2>/dev/null || true
    }
    trap '_fv_cleanup' EXIT INT TERM

    # Ensure destination directory exists
    mkdir -p "${dest_dir}"

    echo "  Downloading: ${url}" >&2
    if ! curl -fsSL \
            --proto '=https' \
            --tlsv1.2 \
            --max-time 300 \
            --output "${tmpfile}" \
            "${url}"; then
        echo "[ERROR] Download failed: ${url}" >&2
        rm -f "${tmpfile}" 2>/dev/null || true
        trap - EXIT INT TERM
        return 1
    fi

    # -----------------------------------------------------------------------
    # DEVBOX_ALLOW_UNVERIFIED=1: documented emergency override
    # -----------------------------------------------------------------------
    if [ "${DEVBOX_ALLOW_UNVERIFIED:-0}" = "1" ]; then
        echo "" >&2
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
        echo "  WARNING: DEVBOX_ALLOW_UNVERIFIED=1 is active.            " >&2
        echo "  Skipping SHA256 verification for: ${url}                 " >&2
        echo "  This is an emergency override. Do NOT use in production. " >&2
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
        echo "" >&2
        mv "${tmpfile}" "${dest}"
        chmod 0644 "${dest}"
        trap - EXIT INT TERM
        return 0
    fi

    # -----------------------------------------------------------------------
    # SHA256 verification
    # -----------------------------------------------------------------------
    local actual_sha256
    actual_sha256=$(sha256sum "${tmpfile}" | awk '{print $1}')

    if [ "${actual_sha256}" != "${expected_sha256}" ]; then
        echo "[ERROR] SHA256 mismatch for: ${url}" >&2
        echo "        Expected: ${expected_sha256}" >&2
        echo "        Got:      ${actual_sha256}" >&2
        rm -f "${tmpfile}" 2>/dev/null || true
        trap - EXIT INT TERM
        return 1
    fi

    echo "  Verified SHA256: ${actual_sha256}" >&2

    # Atomic install
    mv "${tmpfile}" "${dest}"
    chmod 0644 "${dest}"
    trap - EXIT INT TERM
    return 0
}
