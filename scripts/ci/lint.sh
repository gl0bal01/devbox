#!/usr/bin/env bash
# CI lint: run shellcheck + bash -n on every .sh file in the repo.
# Also runs bats unit tests if bats is available.
# Exit non-zero on any failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVBOX_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FAIL=0

# Collect all shell scripts (excluding .git)
mapfile -t ALL_SCRIPTS < <(
    find "${DEVBOX_DIR}" \
        -not -path '*/.git/*' \
        -name '*.sh' \
        -type f \
        | sort
)

echo "Syntax check (bash -n): ${#ALL_SCRIPTS[@]} scripts"
for f in "${ALL_SCRIPTS[@]}"; do
    rel="${f#"${DEVBOX_DIR}/"}"
    if bash -n "${f}" 2>&1; then
        : # ok
    else
        echo "  [FAIL] bash -n: ${rel}" >&2
        FAIL=$((FAIL+1))
    fi
done

echo ""
echo "shellcheck: ${#ALL_SCRIPTS[@]} scripts"

# Determine shellcheck availability
if ! command -v shellcheck >/dev/null 2>&1; then
    echo "  [WARN] shellcheck not installed — skipping static analysis"
else
    for f in "${ALL_SCRIPTS[@]}"; do
        rel="${f#"${DEVBOX_DIR}/"}"
        # --severity=warning: drop info-level style nits (SC2015/2016/2155).
        #   Style fixes welcome as separate PRs; CI gates on warning+ only.
        # SC1091: sourced files not available at lint time (ok for lib/)
        # SC2312: mapfile/process substitution return value (style preference)
        if shellcheck \
                --shell=bash \
                --severity=warning \
                --exclude=SC1091,SC2312 \
                "${f}" 2>&1; then
            : # ok
        else
            echo "  [FAIL] shellcheck: ${rel}" >&2
            FAIL=$((FAIL+1))
        fi
    done
fi

echo ""

# Docs <-> tree consistency
if [ -x "${SCRIPT_DIR}/check-docs-tree.sh" ]; then
    echo "Docs <-> tree consistency"
    if "${SCRIPT_DIR}/check-docs-tree.sh"; then
        : # ok
    else
        echo "  [FAIL] check-docs-tree.sh reported missing paths" >&2
        FAIL=$((FAIL+1))
    fi
    echo ""
fi

# bats unit tests
TESTS_DIR="${DEVBOX_DIR}/tests/unit"
if [ -d "${TESTS_DIR}" ] && command -v bats >/dev/null 2>&1; then
    echo "bats unit tests: ${TESTS_DIR}"
    if bats "${TESTS_DIR}"; then
        : # ok
    else
        echo "  [FAIL] bats tests" >&2
        FAIL=$((FAIL+1))
    fi
elif [ -d "${TESTS_DIR}" ]; then
    echo "[WARN] tests/unit/ exists but bats not installed — skipping"
fi

echo ""
if [ "${FAIL}" -gt 0 ]; then
    echo "[FAIL] ${FAIL} lint failure(s). Fix before merging." >&2
    exit 1
fi
echo "[OK] All lint checks passed."
