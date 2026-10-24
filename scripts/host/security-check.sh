#!/usr/bin/env bash
# Verify the security properties devbox promises on this host. Read-only.
# Exit 1 if any check FAILs. Needs the passwordless `sudo ufw` and
# `sudo sshd -T` entries that setup.sh installs.
set -euo pipefail

export DEVBOX_HOME="${DEVBOX_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=../lib/devbox-contract.sh
. "${DEVBOX_HOME}/lib/devbox-contract.sh"

PASS=0 WARN=0 FAIL=0
pass() { printf '  [ok]   %s\n' "$*"; PASS=$((PASS + 1)); }
warn() { printf '  [warn] %s\n' "$*"; WARN=$((WARN + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }

SSH_PORT="$(devbox_config_get SSH_PORT 5522)"

echo "Network exposure"
# Docker-published ports bypass UFW, so this is the check that matters most.
public=$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E '(0\.0\.0\.0|\[::\]|:::):[0-9]+->' || true)
if [ -z "${public}" ]; then
    pass "No container publishes on all interfaces"
else
    fail "Containers publish on all interfaces (Docker bypasses UFW):"
    printf '         %s\n' "${public}"
fi

wild=$(ss -Hltn | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):[0-9]+$' | grep -vE ":${SSH_PORT}$" | sort -u || true)
if [ -z "${wild}" ]; then
    pass "Only sshd (:${SSH_PORT}) listens on all interfaces"
else
    warn "Host listeners on all interfaces (filtered by UFW; Exegol noVNC is expected here): $(echo "${wild}" | tr '\n' ' ')"
fi

if ufw_status=$(sudo -n ufw status verbose 2>/dev/null); then
    if grep -q '^Status: active' <<<"${ufw_status}" && grep -q 'deny (incoming)' <<<"${ufw_status}"; then
        pass "UFW active, default deny incoming"
    else
        fail "UFW inactive or not denying incoming by default"
    fi
else
    warn "Cannot read UFW status (needs: sudo -n ufw)"
fi

if sshd_cfg=$(sudo -n sshd -T 2>/dev/null); then
    for want in "port ${SSH_PORT}" "passwordauthentication no" "permitrootlogin no" "kbdinteractiveauthentication no"; do
        if grep -qx "${want}" <<<"${sshd_cfg}"; then pass "sshd: ${want}"; else fail "sshd: expected '${want}'"; fi
    done
else
    warn "Cannot read effective sshd config (needs: sudo -n sshd -T)"
fi

echo ""
echo "Containers"
for svc in "${DEVBOX_SERVICES[@]}"; do
    for c in $(devbox_get "${svc}" CONTAINERS); do
        if ! info=$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.HostConfig.SecurityOpt}}|{{.HostConfig.CapDrop}}|{{.HostConfig.Memory}}|{{.HostConfig.Privileged}}|{{.Config.Image}}' "${c}" 2>/dev/null); then
            warn "${c}: not created (stack stopped?)"
            continue
        fi
        IFS='|' read -r state health secopt capdrop mem privileged image <<<"${info}"
        problems=()
        [ "${state}" = running ] || problems+=("state=${state}")
        [ -z "${health}" ] || [ "${health}" = healthy ] || problems+=("health=${health}")
        [[ "${secopt}" == *no-new-privileges* ]] || problems+=("no no-new-privileges")
        [[ "${capdrop}" == *ALL* ]] || problems+=("caps not dropped")
        [ "${mem}" != 0 ] || problems+=("no memory limit")
        [ "${privileged}" = false ] || problems+=("privileged")
        [[ "${image}" =~ @sha256:[0-9a-f]{64}$ ]] || problems+=("image not digest-pinned (${image}): lockfile missing from COMPOSE_FILE")
        if [ ${#problems[@]} -eq 0 ]; then pass "${c}"; else fail "${c}: ${problems[*]}"; fi
    done
done
sock=$(docker ps -q | xargs -r docker inspect -f '{{.Name}} {{range .Mounts}}{{.Source}} {{end}}' | grep '/var/run/docker.sock' | awk '{print substr($1, 2)}' | grep -vx docker-socket-proxy || true)
if [ -z "${sock}" ]; then
    pass "Only docker-socket-proxy mounts the Docker socket"
else
    warn "Containers mounting /var/run/docker.sock: $(echo "${sock}" | tr '\n' ' ')"
fi

echo ""
echo "Secrets"
check_mode() {
    local want="$1" path="$2" got
    [ -e "${path}" ] || return 0
    got=$(stat -c %a "${path}")
    if [ "${got}" = "${want}" ]; then pass "${path#"${DEVBOX_OWNER_HOME}/"} (${got})"; else fail "${path#"${DEVBOX_OWNER_HOME}/"} is ${got}, want ${want}"; fi
}
check_mode 700 "${DEVBOX_SECRETS_DIR}"
for f in "${DEVBOX_SECRETS_DIR}"/* "${DEVBOX_HOME}"/*/.env "${DEVBOX_HOME}/traefik/ovh.env" \
    "${DEVBOX_CONFIG}" "${DEVBOX_CONFIG_DIR}/ovh.env"; do
    check_mode 600 "${f}"
done
for f in "${DEVBOX_HOME}"/traefik/dynamic/*-auth.yml; do
    check_mode 640 "${f}"   # read by Traefik via group_add
done
# Open WebUI persists ENABLE_SIGNUP in its database after first start, so ask
# the running app rather than trusting .env.
signup=$(docker exec openwebui curl -sf http://localhost:8080/api/config 2>/dev/null | jq -r '.features.enable_signup // empty' 2>/dev/null || true)
if [ "${signup}" = true ]; then
    warn "Open WebUI sign-up is open: once the admin exists, disable it in Admin Panel > Settings > General"
fi
if [ -f "${DEVBOX_SECRETS_DIR}/user-password.txt" ]; then
    warn "${DEVBOX_SECRETS_DIR}/user-password.txt still exists: store the password, then delete the file"
fi

echo ""
echo "Summary: ${PASS} ok, ${WARN} warnings, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
