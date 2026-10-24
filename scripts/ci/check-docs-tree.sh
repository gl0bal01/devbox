#!/usr/bin/env bash
# Fail when Markdown docs reference repo paths (services/..., scripts/...,
# tests/..., .github/workflows/...) that do not exist.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
mapfile -t docs < <(ls README.md ARCHITECTURE.md CONTRIBUTING.md CLAUDE.md services/README.md tests/README.md \
    scripts/laptop/README.md docs/*.md 2>/dev/null)

fail=0
for md in "${docs[@]}"; do
    while read -r path; do
        path="${path%[.,:;)\`\'\"]}"
        path="${path%/}"
        case "${path}" in
            services/myservice*|*'<'*|*'*'*) continue ;;   # placeholders and globs
        esac
        if [ ! -e "${path}" ]; then
            echo "[MISS] ${md}: ${path}" >&2
            fail=1
        fi
    done < <(grep -hoE '(\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml|(services|scripts|tests)/[A-Za-z0-9_./<>*-]+)' "${md}" | sort -u)
done
[ "${fail}" -eq 0 ] && echo "[ok] ${#docs[@]} docs reference only existing paths"
exit "${fail}"
