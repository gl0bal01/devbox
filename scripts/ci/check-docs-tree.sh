#!/usr/bin/env bash
# CI check: documentation references resolve to real files in the tree.
#
# Greps every Markdown file under docs/, services/README.md, and README.md
# for paths matching services/.../docker-compose*.yml, services/.../.env.template,
# scripts/**/*.sh, and scripts/lib/*.sh. Each referenced path that begins
# with services/ or scripts/ must exist on disk. Exits non-zero on the
# first miss so docs/tree drift is caught in pr-validate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVBOX_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

MARKDOWN_FILES=(
    "${DEVBOX_DIR}/README.md"
    "${DEVBOX_DIR}/services/README.md"
)
while IFS= read -r f; do
    # Skip docs/adr/ — Architectural Decision Records are historical
    # records, not live truth claims. Drift inside an ADR is expected
    # over time and should not gate CI.
    case "${f}" in
        */docs/adr/*) continue ;;
    esac
    MARKDOWN_FILES+=("${f}")
done < <(find "${DEVBOX_DIR}/docs" -type f -name '*.md' 2>/dev/null | sort)

# Patterns: each referenced path captured here MUST exist on disk.
# Embedded in markdown bodies and code fences alike.
EXTRACT_RE='(services/[A-Za-z0-9_./-]+|scripts/[A-Za-z0-9_./-]+\.sh)'

FAIL=0
declare -A SEEN=()
for md in "${MARKDOWN_FILES[@]}"; do
    [ -f "${md}" ] || continue
    # Extract every match.
    while IFS= read -r path; do
        # Strip trailing punctuation that markdown commonly attaches.
        path="${path%[\`\"\',.\):]}"
        path="${path%/}"
        [ -z "${path}" ] && continue
        # Skip example/placeholder service names used in walkthroughs.
        case "${path}" in
            services/myservice/*) continue ;;
            services/example/*)   continue ;;
        esac
        # Only assert paths that look like real files (have an extension) or
        # are explicit script paths.
        case "${path}" in
            scripts/lib/*)         ;;
            scripts/ci/*)          ;;
            scripts/host/*.sh)     ;;
            scripts/install/*)     ;;
            scripts/*.sh)          ;;
            services/*/docker-compose*.yml) ;;
            services/*/.env.template)       ;;
            services/*/traefik.yml*)        ;;
            services/*/dynamic/*)  ;;
            *) continue ;;
        esac
        # Dedup.
        if [ "${SEEN[${path}]:-}" = "1" ]; then
            continue
        fi
        SEEN[${path}]=1
        if [ ! -e "${DEVBOX_DIR}/${path}" ]; then
            echo "  [MISS] ${md##*/}: refers to ${path} (file not found)" >&2
            FAIL=$((FAIL + 1))
        fi
    done < <(grep -hoE "${EXTRACT_RE}" "${md}" | sort -u)
done

if [ "${FAIL}" -gt 0 ]; then
    echo ""
    echo "[FAIL] ${FAIL} doc-referenced path(s) missing from the tree." >&2
    exit 1
fi
echo "[OK] All doc-referenced paths exist."
