#!/usr/bin/env bash
# CI: generate release notes from digest diff between previous and current commits.
# Output: markdown suitable for a GitHub release body.
#
# Usage: release-notes.sh [<previous-ref>] [<current-ref>]
#   Defaults: previous = HEAD~1, current = HEAD
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVBOX_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PREV_REF="${1:-HEAD~1}"
CURR_REF="${2:-HEAD}"

SERVICES_DIR="services"

# Resolve commits
PREV_SHA=$(git -C "${DEVBOX_DIR}" rev-parse "${PREV_REF}" 2>/dev/null || echo "")
CURR_SHA=$(git -C "${DEVBOX_DIR}" rev-parse "${CURR_REF}" 2>/dev/null || echo "")

if [ -z "${PREV_SHA}" ] || [ -z "${CURR_SHA}" ]; then
    echo "[ERROR] Could not resolve refs: ${PREV_REF} ${CURR_REF}" >&2
    exit 1
fi

CURR_DATE=$(git -C "${DEVBOX_DIR}" log -1 --format='%ci' "${CURR_SHA}" | cut -d' ' -f1)

cat <<HEADER
# devbox Release — ${CURR_DATE}

**Commit**: \`${CURR_SHA:0:12}\`
**Previous**: \`${PREV_SHA:0:12}\`

## Image Digest Changes

HEADER

CHANGED=false

for lock_yml in "${DEVBOX_DIR}/${SERVICES_DIR}"/*/docker-compose.lock.yml; do
    [ -f "${lock_yml}" ] || continue
    svc=$(basename "$(dirname "${lock_yml}")")
    rel_lock="${SERVICES_DIR}/${svc}/docker-compose.lock.yml"

    PREV_CONTENT=$(git -C "${DEVBOX_DIR}" show "${PREV_SHA}:${rel_lock}" 2>/dev/null || true)
    CURR_CONTENT=$(git -C "${DEVBOX_DIR}" show "${CURR_SHA}:${rel_lock}" 2>/dev/null || true)

    if [ -z "${PREV_CONTENT}" ] && [ -z "${CURR_CONTENT}" ]; then
        continue
    fi

    if [ "${PREV_CONTENT}" = "${CURR_CONTENT}" ]; then
        continue
    fi

    echo "### services/${svc}"
    echo ""
    echo '```diff'

    # Extract image lines from each version, diff them
    PREV_IMAGES=$(printf '%s' "${PREV_CONTENT}" | grep -E '^\s+image:' | sed 's/^[[:space:]]*//' || true)
    CURR_IMAGES=$(printf '%s' "${CURR_CONTENT}" | grep -E '^\s+image:' | sed 's/^[[:space:]]*//' || true)

    diff <(printf '%s\n' "${PREV_IMAGES}") <(printf '%s\n' "${CURR_IMAGES}") \
        | grep '^[<>]' \
        | sed 's/^< /- /' \
        | sed 's/^> /+ /' \
        || true

    echo '```'
    echo ""
    CHANGED=true
done

if [ "${CHANGED}" = "false" ]; then
    echo "_No image digest changes between these commits._"
    echo ""
fi

echo "## Commits"
echo ""
git -C "${DEVBOX_DIR}" log \
    --oneline \
    --no-merges \
    "${PREV_SHA}..${CURR_SHA}" \
    | sed 's/^/- /'
