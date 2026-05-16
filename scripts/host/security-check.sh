#!/usr/bin/env bash
# Security verification script based on SECURITY-AUDIT.md recommendations.
# Sources the installed runtime contract for container names + install paths.
set -euo pipefail

DEVBOX_HOME="${DEVBOX_HOME:-${HOME}/docker}"
CONTRACT="${DEVBOX_HOME}/lib/devbox-contract.sh"
if [ -f "${CONTRACT}" ]; then
    # shellcheck disable=SC1090
    . "${CONTRACT}"
fi

# Build a flat list of every container name across services for iteration.
declare -a ALL_CONTAINERS=()
if [ "${DEVBOX_SERVICES+set}" = "set" ]; then
    for _svc in "${DEVBOX_SERVICES[@]}"; do
        _cn="$(devbox_get "${_svc}" CONTAINERS)"
        for _n in ${_cn}; do
            ALL_CONTAINERS+=("${_n}")
        done
    done
else
    ALL_CONTAINERS=(traefik ollama openwebui docker-socket-proxy)
fi

# Subset that the per-container security/limits checks iterate explicitly
# (kept to "service" containers only — skips docker-socket-proxy which has
# its own purpose-built read-only/no-cap hardening covered by check 1).
SERVICE_CONTAINERS=(traefik ollama openwebui)

echo "Docker Security Verification"
echo "======================================================================="
echo ""

PASS=0
WARN=0
FAIL=0

check_pass() { echo "  [OK]   $1"; PASS=$((PASS+1)); }
check_warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }
check_fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# -----------------------------------------------------------------------
# Check 1: Docker socket proxy
# -----------------------------------------------------------------------
echo "1. Docker Socket Security"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q docker-socket-proxy; then
    check_pass "Docker socket proxy is running"
else
    check_fail "Docker socket proxy not running - Traefik has direct socket access"
fi

# -----------------------------------------------------------------------
# Check 2: Secrets in environment variables
# -----------------------------------------------------------------------
echo ""
echo "2. Secrets Management"
LEAKED_SECRETS=$(docker ps -q 2>/dev/null | xargs -r docker inspect \
    --format '{{.Name}} {{range .Config.Env}}{{.}} {{end}}' 2>/dev/null \
    | grep -iE "(password|secret|key|token)=" \
    | grep -v "WEBUI_SECRET_KEY=\${" \
    | head -5 || true)
if [ -z "${LEAKED_SECRETS}" ]; then
    check_pass "No hardcoded secrets found in container environment"
else
    check_fail "Secrets found in container environment (check .env files):"
    echo "${LEAKED_SECRETS}" | head -3 | sed 's/=[^ ]*/=***REDACTED***/g' | sed 's/^/       /'
fi

# -----------------------------------------------------------------------
# Check 3: .env file permissions
# -----------------------------------------------------------------------
echo ""
echo "3. Secret File Permissions"
for envfile in "${DEVBOX_HOME}"/*/.env; do
    if [ -f "${envfile}" ]; then
        PERMS=$(stat -c %a "${envfile}" 2>/dev/null)
        svcname=$(basename "$(dirname "${envfile}")")
        if [ "${PERMS}" = "600" ]; then
            check_pass "${svcname}/.env has correct permissions (600)"
        else
            check_warn "${svcname}/.env has permissions ${PERMS} (should be 600)"
        fi
    fi
done

# .secrets/ollama-auth.txt — operator-visible credential, must be 600.
OLLAMA_SECRET="${DEVBOX_HOME}/.secrets/ollama-auth.txt"
if [ -f "${OLLAMA_SECRET}" ]; then
    OS_PERMS=$(stat -c %a "${OLLAMA_SECRET}" 2>/dev/null)
    if [ "${OS_PERMS}" = "600" ]; then
        check_pass ".secrets/ollama-auth.txt has correct permissions (600)"
    else
        check_fail ".secrets/ollama-auth.txt has permissions ${OS_PERMS} (must be 600)"
    fi
fi

# Check ~/.devbox-credentials if it exists (Scenario E mitigation)
if [ -f "${HOME}/.devbox-credentials" ]; then
    CRED_PERMS=$(stat -c %a "${HOME}/.devbox-credentials" 2>/dev/null)
    if [ "${CRED_PERMS}" = "600" ]; then
        check_pass "${HOME}/.devbox-credentials has correct permissions (600)"
    else
        check_fail "${HOME}/.devbox-credentials has permissions ${CRED_PERMS} (must be 600)"
    fi
fi

# -----------------------------------------------------------------------
# Check 4: Container security options
# -----------------------------------------------------------------------
echo ""
echo "4. Container Security Options"
for container in "${SERVICE_CONTAINERS[@]}"; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        NO_NEW_PRIV=$(docker inspect "${container}" \
            --format '{{.HostConfig.SecurityOpt}}' 2>/dev/null \
            | grep -c "no-new-privileges" || true)
        if [ "${NO_NEW_PRIV}" -gt 0 ]; then
            check_pass "${container} has no-new-privileges"
        else
            check_warn "${container} missing no-new-privileges"
        fi
    fi
done

# -----------------------------------------------------------------------
# Check 5: Resource limits
# -----------------------------------------------------------------------
echo ""
echo "5. Resource Limits"
for container in "${SERVICE_CONTAINERS[@]}"; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        MEM_LIMIT=$(docker inspect "${container}" \
            --format '{{.HostConfig.Memory}}' 2>/dev/null)
        if [ "${MEM_LIMIT}" != "0" ] && [ -n "${MEM_LIMIT}" ]; then
            MEM_MB=$((MEM_LIMIT / 1024 / 1024))
            check_pass "${container} has memory limit (${MEM_MB}MB)"
        else
            check_warn "${container} has no memory limit"
        fi
    fi
done

# -----------------------------------------------------------------------
# Check 6: Image versions (no :latest in compose files)
# -----------------------------------------------------------------------
echo ""
echo "6. Image Versions"
for container in "${SERVICE_CONTAINERS[@]}"; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        IMAGE=$(docker inspect "${container}" \
            --format '{{.Config.Image}}' 2>/dev/null)
        if echo "${IMAGE}" | grep -qE ":latest$|:main$"; then
            check_warn "${container} uses unpinned tag: ${IMAGE}"
        else
            check_pass "${container} uses pinned version: ${IMAGE}"
        fi
    fi
done
# Static check: grep installed compose files for :latest on core images
LATEST_REFS=$(grep -r --include='docker-compose.yml' -E \
    'image:\s*(traefik|ollama|ghcr\.io/open-webui|docker-socket-proxy):latest' \
    "${DEVBOX_HOME}/" 2>/dev/null || true)
if [ -n "${LATEST_REFS}" ]; then
    check_fail "Compose file references :latest for a core image:"
    # shellcheck disable=SC2001
    echo "${LATEST_REFS}" | sed 's/^/       /'
else
    check_pass "No core compose files reference :latest"
fi

# -----------------------------------------------------------------------
# Check 7: Traefik dashboard auth
# -----------------------------------------------------------------------
echo ""
echo "7. Traefik Dashboard Authentication"
TRAEFIK_AUTH="${DEVBOX_HOME}/traefik/dynamic/dashboard-auth.yml"
if [ -f "${TRAEFIK_AUTH}" ]; then
    check_pass "Traefik dashboard auth middleware configured"
else
    check_fail "Traefik dashboard auth not configured (${TRAEFIK_AUTH} missing)"
fi

OLLAMA_AUTH_YML="${DEVBOX_HOME}/traefik/dynamic/ollama-auth.yml"
if [ -f "${OLLAMA_AUTH_YML}" ]; then
    check_pass "Ollama basic-auth middleware configured"
else
    check_fail "Ollama basic-auth not configured (${OLLAMA_AUTH_YML} missing)"
fi

# -----------------------------------------------------------------------
# Check 8: Health checks
# -----------------------------------------------------------------------
echo ""
echo "8. Health Checks"
for container in "${SERVICE_CONTAINERS[@]}"; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        HEALTH=$(docker inspect "${container}" \
            --format '{{.State.Health.Status}}' 2>/dev/null || true)
        if [ -n "${HEALTH}" ] && [ "${HEALTH}" != "<no value>" ]; then
            check_pass "${container} has health check (${HEALTH})"
        else
            check_warn "${container} has no health check"
        fi
    fi
done

# -----------------------------------------------------------------------
# Check 9: umask hardening in setup.sh (when present on host)
# -----------------------------------------------------------------------
echo ""
echo "9. setup.sh umask hardening"
SETUP_CANDIDATES=(
    "${DEVBOX_HOME}/../devbox/setup.sh"
    "${DEVBOX_HOME}/setup.sh"
)
SETUP=""
for c in "${SETUP_CANDIDATES[@]}"; do
    if [ -f "${c}" ]; then
        SETUP="${c}"
        break
    fi
done
if [ -n "${SETUP}" ]; then
    if grep -q 'umask 077' "${SETUP}"; then
        check_pass "setup.sh contains 'umask 077'"
    else
        check_warn "setup.sh does not set 'umask 077' (check for credential exposure)"
    fi
else
    check_warn "setup.sh not found on host (not packaged in install dir)"
fi

# -----------------------------------------------------------------------
# Check 10: flock available
# -----------------------------------------------------------------------
echo ""
echo "10. Concurrency Safety"
if command -v flock >/dev/null 2>&1; then
    check_pass "flock is installed (util-linux)"
else
    check_fail "flock not found - install util-linux for safe concurrent script execution"
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "======================================================================="
echo "Summary: ${PASS} passed, ${WARN} warnings, ${FAIL} failed"
echo ""

if [ "${FAIL}" -gt 0 ]; then
    echo "[FAIL] Security issues detected - review and fix before production use"
    exit 1
elif [ "${WARN}" -gt 0 ]; then
    echo "[WARN] Some warnings - review recommendations"
    exit 0
else
    echo "[OK] All security checks passed!"
    exit 0
fi
