#!/usr/bin/env bash
# End-to-end test: install devbox for real, then exercise it.
#
# DESTRUCTIVE TO THE HOST IT RUNS ON: creates a user, moves sshd, enables
# UFW. Run only on a disposable Ubuntu 24.04 machine with Docker: the GitHub
# runner (pr-validate.yml) or the throwaway container from e2e-container.sh.
#
# Covers what static tests cannot: install from scratch, routing and basic
# auth through Traefik, credential rotation, idempotent re-run, digest locks
# in effect, backup -> wipe -> restore round trip, systemd units.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root on a disposable host" >&2; exit 1; }
[ "${DEVBOX_E2E_I_UNDERSTAND:-}" = yes ] || { echo "set DEVBOX_E2E_I_UNDERSTAND=yes: this reconfigures the host" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
U=e2edev
H="/home/${U}"
D="${H}/docker"
step() { printf '\n\033[1;36m== e2e: %s\033[0m\n' "$*"; }
ok()   { printf '   ok: %s\n' "$*"; }
as_u() { ( cd "${H}" && sudo -u "${U}" -H -- "$@" ); }

# curl_in <host> [user:pass] [path] — HTTP status of a request made from
# inside the traefik container, where the source IP (127.0.0.1) passes the
# Tailscale allowlist.
curl_in() {
    local auth=()
    [ -n "${2:-}" ] && auth=(--header "Authorization: Basic $(printf '%s' "$2" | base64 -w0)")
    { docker exec traefik wget -q -S -O /dev/null --header "Host: $1" "${auth[@]}" "http://127.0.0.1${3:-/}" 2>&1 || true; } \
        | grep -oE 'HTTP/[0-9.]+ [0-9]{3}' | tail -n1 | cut -d' ' -f2
}
expect() {
    if [ "$2" != "$3" ]; then
        echo "FAIL: $1: expected $3, got ${2:-no response}" >&2
        docker logs --tail 30 traefik >&2 || true
        exit 1
    fi
    ok "$1 -> $3"
}
# check <description> <command...> — fail the run unless the command succeeds.
check() { local d="$1"; shift; if "$@"; then ok "${d}"; else echo "FAIL: ${d}" >&2; exit 1; fi; }

ssh-keygen -q -t ed25519 -N '' -f /tmp/e2e_key <<<y >/dev/null
SSH_PUBLIC_KEY="$(cat /tmp/e2e_key.pub)"
export DEVBOX_USER="${U}" SSH_PUBLIC_KEY DEVBOX_ALLOW_NO_TAILSCALE=true DEVBOX_SSH_PORT=5522

step "fresh install"
"${REPO}/setup.sh" --yes --no-upgrade

step "host hardening"
effective="$(sshd -T)"
check "sshd port 5522" grep -qx 'port 5522' <<<"${effective}"
check "password auth off" grep -qx 'passwordauthentication no' <<<"${effective}"
check "root login off" grep -qx 'permitrootlogin no' <<<"${effective}"
check "sshd listening on 5522" test -n "$(ss -Hltn '( sport = :5522 )')"
ufw_status="$(ufw status)"
check "ufw active" grep -q '^Status: active' <<<"${ufw_status}"
check "ufw allows 5522" grep -Eq '^5522/tcp +ALLOW' <<<"${ufw_status}"
check "fail2ban sshd jail" fail2ban-client status sshd
check "docker log rotation configured" jq -e 'has("log-driver")' /etc/docker/daemon.json
check "ip_nonlocal_bind" test "$(sysctl -n net.ipv4.ip_nonlocal_bind)" = 1
check "/run/devbox owned by ${U}" test "$(stat -c %U /run/devbox)" = "${U}"
check "mise toolchain on login PATH" as_u bash -lc 'command -v exegol nvim lazygit lazydocker zellij bun node uv cargo'
check "oh-my-zsh" test -f "${H}/.oh-my-zsh/oh-my-zsh.sh"

step "stack up"
as_u "${D}/start-all.sh"
dash="$(cat "${D}/.secrets/traefik-dashboard.txt")"
oll="$(cat "${D}/.secrets/ollama-auth.txt")"
expect "open webui" "$(curl_in ai.internal)" 200
expect "ollama without auth" "$(curl_in ollama.internal '' /api/version)" 401
expect "ollama with auth" "$(curl_in ollama.internal "${oll}" /api/version)" 200
expect "dashboard with auth" "$(curl_in traefik.internal "${dash}" /api/overview)" 200
expect "unknown host" "$(curl_in nope.internal)" 404
for c in traefik docker-socket-proxy ollama openwebui; do
    img="$(docker inspect -f '{{.Config.Image}}' "${c}")"
    check "${c} runs the locked digest" grep -Eq '@sha256:[0-9a-f]{64}$' <<<"${img}"
done
check "security-check passes" as_u "${D}/security-check.sh"

step "rotate ollama credential"
as_u "${D}/rotate-ollama-auth.sh"
sleep 3   # Traefik file watcher
expect "old credential" "$(curl_in ollama.internal "${oll}" /api/version)" 401
oll="$(cat "${D}/.secrets/ollama-auth.txt")"
expect "new credential" "$(curl_in ollama.internal "${oll}" /api/version)" 200

step "idempotent re-run"
"${REPO}/setup.sh" --yes --no-upgrade
as_u "${D}/start-all.sh"
sleep 3
expect "ollama credential survives re-run" "$(curl_in ollama.internal "${oll}" /api/version)" 200
expect "dashboard credential survives re-run" "$(curl_in traefik.internal "${dash}" /api/overview)" 200

step "backup -> wipe -> restore"
docker exec openwebui sh -c 'echo e2e > /app/backend/data/e2e-marker'
as_u "${D}/backup.sh"
archive=$(ls -1 "${H}"/.local/share/devbox/backups/devbox-backup-*.tar | tail -n1)
manifest="$(tar -xOf "${archive}" ./MANIFEST)"
check "openwebui volume archived, ollama models excluded" grep -qx 'volumes=ollama-openwebui_openwebui-data' <<<"${manifest}"
docker exec openwebui rm /app/backend/data/e2e-marker
as_u "${D}/restore.sh" --yes "${archive}"
check "volume restored" test "$(docker exec openwebui cat /app/backend/data/e2e-marker)" = e2e
expect "auth after restore" "$(curl_in ollama.internal "${oll}" /api/version)" 200

step "systemd units"
"${D}/install-systemd.sh"
systemctl start devbox.service
check "devbox.service active" systemctl is-active --quiet devbox.service
check "devbox-backup.timer enabled" systemctl is-enabled --quiet devbox-backup.timer

step "stop"
systemctl stop devbox.service
check "stack stopped" test -z "$(docker ps -q --filter label=com.docker.compose.project=ollama-openwebui)"

printf '\n\033[1;32mE2E PASSED\033[0m\n'
