#!/usr/bin/env bash
# Lint every shell script: bash -n, then shellcheck (warning and above).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
mapfile -t files < <( { git ls-files --cached --others --exclude-standard '*.sh' '*.bash' 2>/dev/null || find . -name '*.sh' -not -path './.git/*'; echo .githooks/pre-push; } | sort -u)

fail=0
for f in "${files[@]}"; do
    bash -n "${f}" || { echo "[FAIL] bash -n ${f}" >&2; fail=1; }
done
shellcheck --shell=bash --external-sources --severity=warning --exclude=SC1091 "${files[@]}" || fail=1
[ "${fail}" -eq 0 ] && echo "[ok] ${#files[@]} scripts lint clean"
exit "${fail}"
