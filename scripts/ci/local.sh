#!/usr/bin/env bash
# Local mirror of .github/workflows/pr-validate.yml: same jobs, same order.
# Runs every step even after a failure and prints a summary with log paths.
#
#   scripts/ci/local.sh          static job + e2e job
#   scripts/ci/local.sh --fast   static job only (e2e reported as skipped)
#
# The e2e job reconfigures the machine it runs on (users, sshd, UFW). CI uses
# a disposable runner; locally it runs in the throwaway container from
# scripts/ci/e2e-container.sh, which is the only difference from CI.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
FAST=false
[ "${1:-}" = --fast ] && FAST=true
LOGS="${TMPDIR:-/tmp}/devbox-ci-$(date +%Y%m%dT%H%M%S)"
mkdir -p "${LOGS}"
results=()

run() {
    local name="$1" start rc
    shift
    start=$(date +%s)
    printf '%-28s ' "${name}"
    "$@" >"${LOGS}/${name}.log" 2>&1
    rc=$?
    if [ "${rc}" -eq 0 ]; then
        printf 'PASS (%ss)\n' "$(( $(date +%s) - start ))"
        results+=("PASS ${name}")
    else
        printf 'FAIL (%ss)  %s\n' "$(( $(date +%s) - start ))" "${LOGS}/${name}.log"
        results+=("FAIL ${name}")
    fi
}

echo "job static"
run lint            scripts/ci/lint.sh
run docs-tree       scripts/ci/check-docs-tree.sh
run bats            bats tests/unit tests/contract   # CI installs bats first (apt)
run compose-config  scripts/ci/check-compose-config.sh

echo "job e2e"
if ${FAST}; then
    printf '%-28s SKIPPED (--fast): CI still runs it\n' e2e-install
    results+=("SKIP e2e-install")
else
    run e2e-install scripts/ci/e2e-container.sh
fi

echo ""
echo "logs: ${LOGS}"
printf '%s\n' "${results[@]}" | grep -q '^FAIL' && { echo "RESULT: FAIL"; exit 1; }
echo "RESULT: PASS"
