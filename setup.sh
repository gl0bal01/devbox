#!/usr/bin/env bash
# =============================================================================
# DevBox setup.sh — host bootstrapper for Ubuntu 24.04
# =============================================================================
# Converges the host layer (packages, vendor repos, Tailscale, operator user,
# Docker defaults, dev toolchain) and syncs the tracked stack (services/,
# scripts/host/, scripts/lib/, scripts/systemd/) into ~/docker/.
#
# Guarantees:
#   - Every check runs before the first host change (see preflight).
#   - Re-runs converge: generated secrets, operator .env edits and ACME state
#     are preserved; derived files are re-rendered from persisted state.
#   - SSH and firewall lockdown run last, and UFW is only touched after sshd
#     is verified listening on the configured port with key-only auth.
#
# Design notes: ARCHITECTURE.md. Usage: ./setup.sh --help
# =============================================================================
set -euo pipefail
umask 077

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'USAGE'
Usage: sudo -E ./setup.sh [OPTIONS]   (-E keeps the variables below; sudo drops them otherwise)

Options:
  -y, --yes        Non-interactive: no prompts, existing UFW rules are reset.
  --check          Report repo sanity and installed-contract drift. No root.
  --dry-run        Run every preflight check and print the plan. No changes.
  --no-upgrade     Skip `apt-get upgrade` (packages are still installed).
  --no-dev-tools   Skip the mise toolchain, Oh My Zsh, LazyVim and .zshrc.
  -h, --help       Show this help.

Environment (first install; later runs reuse ~/.config/devbox/config.env):
  DEVBOX_USER              operator account                 (default: dev)
  DEVBOX_SSH_PORT          sshd port                        (default: 5522)
  SSH_PUBLIC_KEY           public key for the operator      (or ~/.ssh/devbox_authorized_key)
  ENABLE_HTTPS             true = Let's Encrypt via OVH DNS-01 (default: false)
  DEVBOX_DOMAIN            domain for HTTPS hosts (ai.<domain>, ollama.<domain>)
  DEVBOX_EMAIL             ACME account email (HTTPS)
  DEVBOX_OVH_ENV           path to ovh.env (default: ~/.config/devbox/ovh.env)
  DEVBOX_GPU               none | nvidia                    (default: none)
  TAILSCALE_AUTHKEY        join the tailnet non-interactively
  DEVBOX_TAILSCALE_UP_ARGS extra `tailscale up` flags, e.g. --advertise-tags=tag:devbox
  DEVBOX_ALLOW_NO_TAILSCALE=true  bind to 127.0.0.1 when Tailscale is not up (CI)
USAGE
}

OPT_YES=false OPT_CHECK=false OPT_DRY_RUN=false OPT_UPGRADE=true OPT_DEV_TOOLS=true
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)       OPT_YES=true ;;
        --check)        OPT_CHECK=true ;;
        --dry-run)      OPT_DRY_RUN=true ;;
        --no-upgrade)   OPT_UPGRADE=false ;;
        --no-dev-tools) OPT_DEV_TOOLS=false ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

for f in scripts/lib/devbox-contract.sh scripts/lib/devbox-lib.sh scripts/lib/pins.sh; do
    [ -f "${REPO_DIR}/${f}" ] || { echo "Missing ${f}: run setup.sh from a complete devbox checkout." >&2; exit 1; }
done

# Operator: DEVBOX_USER, else the one recorded by a previous run in the
# root-owned /etc/devbox/operator (never inferred from user-writable paths,
# which any local user could plant), else `dev`. --check without root
# inspects the caller's own install.
OPERATOR_FILE=/etc/devbox/operator
NEW_USER="${DEVBOX_USER:-}"
if [ -z "${NEW_USER}" ] && ${OPT_CHECK} && [ "$(id -u)" -ne 0 ]; then
    NEW_USER="$(id -un)"
elif [ -z "${NEW_USER}" ] && [ -f "${OPERATOR_FILE}" ] \
    && [ "$(stat -c '%U %a' "${OPERATOR_FILE}")" = "root 644" ] && [ "$(stat -c %U /etc/devbox)" = root ]; then
    NEW_USER="$(head -n1 "${OPERATOR_FILE}")"
fi
NEW_USER="${NEW_USER:-dev}"
[[ "${NEW_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "Invalid DEVBOX_USER: ${NEW_USER}" >&2; exit 2; }
if TARGET_HOME=$(getent passwd "${NEW_USER}" | cut -d: -f6) && [ -n "${TARGET_HOME}" ]; then
    USER_EXISTS=true
else
    USER_EXISTS=false
    TARGET_HOME="/home/${NEW_USER}"
fi

# The contract derives every install path from DEVBOX_HOME.
DEVBOX_HOME="${TARGET_HOME}/docker"
# shellcheck source=scripts/lib/devbox-contract.sh
. "${REPO_DIR}/scripts/lib/devbox-contract.sh"
# shellcheck source=scripts/lib/devbox-lib.sh
. "${REPO_DIR}/scripts/lib/devbox-lib.sh"
# shellcheck source=scripts/lib/pins.sh
. "${REPO_DIR}/scripts/lib/pins.sh"

# -----------------------------------------------------------------------------
# --check: contract drift between the repo and the installed copy
# -----------------------------------------------------------------------------
if ${OPT_CHECK}; then
    installed="${DEVBOX_HOME}/lib/devbox-contract.sh"
    if [ ! -f "${DEVBOX_HOME}/lib/.devbox-marker" ]; then
        log "No install at ${DEVBOX_HOME} (marker absent)."
        exit 0
    fi
    [ -f "${installed}" ] || die "Marker present but ${installed} is missing. Re-run setup.sh."
    if cmp -s "${REPO_DIR}/scripts/lib/devbox-contract.sh" "${installed}"; then
        log "Installed contract matches the repo."
        exit 0
    fi
    warn "Installed contract differs from the repo. Re-run: sudo ./setup.sh --yes"
    diff -u "${installed}" "${REPO_DIR}/scripts/lib/devbox-contract.sh" || true
    exit 1
fi

# -----------------------------------------------------------------------------
# Configuration: environment > previous config.env > defaults
# -----------------------------------------------------------------------------
# Installs from before config.env recorded SSH_PORT kept it only in their
# 99-hardening.conf drop-in: fall back to it so an upgrade never moves sshd.
SSH_PORT="${DEVBOX_SSH_PORT:-$(devbox_config_get SSH_PORT)}"
SSH_PORT="${SSH_PORT:-$(awk '/^Port /{print $2; exit}' /etc/ssh/sshd_config.d/99-hardening.conf 2>/dev/null || true)}"
SSH_PORT="${SSH_PORT:-5522}"
ENABLE_HTTPS="${ENABLE_HTTPS:-$(devbox_config_get ENABLE_HTTPS false)}"
DOMAIN="${DEVBOX_DOMAIN:-$(devbox_config_get DOMAIN)}"
ACME_EMAIL="${DEVBOX_EMAIL:-$(devbox_config_get ACME_EMAIL)}"
GPU="${DEVBOX_GPU:-$(devbox_config_get GPU none)}"
read -r -a TS_UP_ARGS <<<"${DEVBOX_TAILSCALE_UP_ARGS:-}"

PACKAGES=(
    age build-essential ca-certificates curl dnsutils fail2ban gawk gettext-base
    git gnupg htop iputils-ping jq locales nano ncdu openssh-server openvpn
    python3-systemd rsync tmux tree ufw unattended-upgrades unzip util-linux vim wget wireguard-tools zsh
)
# Helpers removed from scripts/host/; deleted from old installs on upgrade.
RETIRED_HELPERS=(harden-dnat-scope.sh harden-fail2ban.sh harden-backup-skeleton.sh)

SSHD_DROPIN=/etc/ssh/sshd_config.d/00-devbox.conf
SSHD_LEGACY_DROPIN=/etc/ssh/sshd_config.d/99-hardening.conf
SNAPSHOT_DIR="${TARGET_HOME}/.local/share/devbox/backups/setup-$(date -u +%Y%m%dT%H%M%SZ)"
FAILED_STEPS=()

# snapshot <path> — keep a copy of a file before setup.sh replaces it.
snapshot() {
    [ -e "$1" ] || return 0
    install -d -m 0700 "${SNAPSHOT_DIR}"
    cp -a "$1" "${SNAPSHOT_DIR}/$(printf '%s' "$1" | tr '/' '_')"
}

# as_user <cmd...> — run as the operator from their home directory.
as_user() {
    ( cd "${TARGET_HOME}" && sudo -u "${NEW_USER}" -H \
        --preserve-env=MISE_GITHUB_TOKEN,GITHUB_TOKEN -- "$@" )
}

# Locate ovh.env (HTTPS) and parse it without sourcing: it is operator-owned.
find_ovh_env() {
    local c
    for c in "${DEVBOX_OVH_ENV:-}" "${DEVBOX_CONFIG_DIR}/ovh.env" "${HOME}/.config/devbox/ovh.env"; do
        [ -n "${c}" ] && [ -f "${c}" ] && { printf '%s' "${c}"; return 0; }
    done
    return 1
}

# Resolve the operator's public key (may be empty when authorized_keys exists).
resolve_ssh_key() {
    local c
    if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
        printf '%s' "${SSH_PUBLIC_KEY}"
        return 0
    fi
    for c in "${HOME}/.ssh/devbox_authorized_key" /root/.ssh/devbox_authorized_key; do
        [ -f "${c}" ] && { head -n1 "${c}"; return 0; }
    done
    return 0
}

tailscale_ip() { tailscale ip -4 2>/dev/null | head -n1 || true; }

# -----------------------------------------------------------------------------
# Preflight — read-only. Collects every problem, then fails once.
# -----------------------------------------------------------------------------
PREFLIGHT_ERRORS=()
preflight_fail() { PREFLIGHT_ERRORS+=("$1"); }

preflight() {
    if [ "$(id -u)" -ne 0 ] && ! ${OPT_DRY_RUN}; then
        preflight_fail "Run as root: sudo ./setup.sh"
    fi
    # shellcheck disable=SC1091
    if ! ( . /etc/os-release && [ "${ID}" = ubuntu ] && [ "${VERSION_ID}" = "24.04" ] ); then
        warn "Built and tested for Ubuntu 24.04; continuing on $(. /etc/os-release && echo "${PRETTY_NAME}")."
    fi
    [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] && [ "${SSH_PORT}" -ge 1 ] && [ "${SSH_PORT}" -le 65535 ] \
        || preflight_fail "DEVBOX_SSH_PORT must be 1-65535 (got '${SSH_PORT}')."
    case "${ENABLE_HTTPS}" in true|false) ;; *) preflight_fail "ENABLE_HTTPS must be true or false." ;; esac
    case "${GPU}" in none|nvidia) ;; *) preflight_fail "DEVBOX_GPU must be none or nvidia." ;; esac

    if ! command -v docker >/dev/null 2>&1; then
        preflight_fail "Docker is not installed (install docker-ce or docker.io first)."
    elif ! docker info >/dev/null 2>&1; then
        preflight_fail "Docker daemon is not reachable."
    elif ! docker compose version >/dev/null 2>&1; then
        preflight_fail "Docker Compose v2 plugin missing (package docker-compose-plugin or docker-compose-v2)."
    elif [ "${GPU}" = nvidia ] && ! docker info --format '{{json .Runtimes}}' | grep -q nvidia \
        && ! command -v nvidia-container-runtime-hook >/dev/null && ! command -v nvidia-ctk >/dev/null; then
        preflight_fail "DEVBOX_GPU=nvidia but the NVIDIA Container Toolkit is not installed."
    fi
    if [ -s /etc/docker/daemon.json ] && ! jq -e . /etc/docker/daemon.json >/dev/null 2>&1; then
        preflight_fail "/etc/docker/daemon.json is not valid JSON."
    fi
    if [ "$(id -u)" -eq 0 ]; then
        holder=$(ss -Hltnp "( sport = :${SSH_PORT} )" | grep -vE 'users:\(\("(sshd|systemd)"' || true)
        [ -z "${holder}" ] || preflight_fail "Port ${SSH_PORT} is already used by another process: ${holder}"
    fi

    SSH_KEY="$(resolve_ssh_key)"
    if [ -n "${SSH_KEY}" ]; then
        ssh-keygen -l -f /dev/stdin <<<"${SSH_KEY}" >/dev/null 2>&1 \
            || preflight_fail "SSH_PUBLIC_KEY is not a valid public key."
    elif [ ! -s "${TARGET_HOME}/.ssh/authorized_keys" ]; then
        preflight_fail "No SSH public key: set SSH_PUBLIC_KEY or write ~/.ssh/devbox_authorized_key. Password login is disabled at the end, so installing without a key would lock you out."
    fi

    if [ "${ENABLE_HTTPS}" = true ]; then
        [ -n "${DOMAIN}" ] && [ "${DOMAIN}" != example.com ] || preflight_fail "ENABLE_HTTPS=true requires DEVBOX_DOMAIN."
        [ -n "${ACME_EMAIL}" ] || preflight_fail "ENABLE_HTTPS=true requires DEVBOX_EMAIL (Let's Encrypt account)."
        if OVH_ENV_SRC=$(find_ovh_env); then
            local k
            for k in OVH_ENDPOINT OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY; do
                [ -n "$(env_get "${OVH_ENV_SRC}" "${k}")" ] || preflight_fail "${OVH_ENV_SRC} lacks ${k}."
            done
        else
            preflight_fail "ENABLE_HTTPS=true requires ovh.env (DEVBOX_OVH_ENV or ${DEVBOX_CONFIG_DIR}/ovh.env)."
        fi
    fi

    if command -v tailscale >/dev/null 2>&1 && [ -n "$(tailscale_ip)" ]; then
        :
    elif [ -n "${TAILSCALE_AUTHKEY:-}" ] || ! ${OPT_YES}; then
        :   # joined during install (auth key, or interactive login URL)
    elif [ "${DEVBOX_ALLOW_NO_TAILSCALE:-false}" = true ]; then
        warn "Tailscale is not up: services will bind to 127.0.0.1 (DEVBOX_ALLOW_NO_TAILSCALE=true)."
    else
        preflight_fail "--yes needs Tailscale up already, TAILSCALE_AUTHKEY, or DEVBOX_ALLOW_NO_TAILSCALE=true."
    fi

    collision_guard "${DEVBOX_HOME}" "${REPO_DIR}" 2>/dev/null \
        || preflight_fail "$(collision_guard "${DEVBOX_HOME}" "${REPO_DIR}" 2>&1)"

    if [ ${#PREFLIGHT_ERRORS[@]} -gt 0 ]; then
        printf '%s[xx]%s %s\n' "${_C_RED}" "${_C_NC}" "${PREFLIGHT_ERRORS[@]}" >&2
        return 1
    fi
    log "Preflight passed."
}

print_plan() {
    cat <<PLAN

Configuration
  user            ${NEW_USER} (${TARGET_HOME}, $(${USER_EXISTS} && echo exists || echo "will be created"))
  ssh port        ${SSH_PORT} (key-only; password and root login disabled)
  https           ${ENABLE_HTTPS}${DOMAIN:+ (ai.${DOMAIN}, ollama.${DOMAIN})}
  gpu             ${GPU}
  install root    ${DEVBOX_HOME}
  dev tools       ${OPT_DEV_TOOLS}

Plan
  1 packages      apt-get update$(${OPT_UPGRADE} && echo " + upgrade"); install: ${PACKAGES[*]}
  2 vendor repos  tailscale + mise apt repos (signing keys checked against scripts/lib/pins.sh)
  3 tailscale     join the tailnet if needed; services bind to its IPv4
  4 user          ${NEW_USER} in sudo + docker groups, /etc/sudoers.d/90-${NEW_USER}, /run/devbox
  5 docker        log rotation defaults in /etc/docker/daemon.json, ip_nonlocal_bind, proxy-net
  6 dev tools     /etc/mise/config.toml + mise install, Oh My Zsh @ ${OHMYZSH_COMMIT:0:12}, LazyVim, .zshrc
  7 stack         ${DEVBOX_HOME}: ${DEVBOX_SERVICES[*]} + helpers; secrets in ${DEVBOX_SECRETS_DIR}
  8 lockdown      ${SSHD_DROPIN}, fail2ban sshd jail, UFW: deny incoming except ${SSH_PORT}/tcp
PLAN
}

if ${OPT_DRY_RUN}; then
    echo "[dry-run] No changes will be made."
    preflight_rc=0
    preflight || preflight_rc=$?
    print_plan
    echo ""
    echo "Files that would change under ${DEVBOX_HOME}:"
    for svc in "${DEVBOX_SERVICES[@]}"; do
        echo "  [${svc}]"
        if [ -d "${DEVBOX_HOME}/${svc}" ]; then
            rsync -an --itemize-changes --delete "${RSYNC_EXCLUDES[@]}" \
                "${REPO_DIR}/services/${svc}/" "${DEVBOX_HOME}/${svc}/" 2>/dev/null | sed 's/^/    /'
        else
            echo "    (new install: all files)"
        fi
    done
    exit "${preflight_rc}"
fi

preflight || exit 1

# /run, unlike the world-writable /run/lock, cannot be pre-seeded by other users.
exec 9>/run/devbox-setup.lock
flock -n 9 || die "Another setup.sh is running (lock: /run/devbox-setup.lock)."

print_plan
if ! ${OPT_YES}; then
    read -r -p "Proceed? [y/N] " reply
    [[ "${reply}" =~ ^[Yy]$ ]] || exit 0
fi
START_TIME=$(date +%s)

# -----------------------------------------------------------------------------
phase "1/8 Packages"
# -----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8
APT=(apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
"${APT[@]}" update
if ${OPT_UPGRADE}; then
    "${APT[@]}" upgrade
fi
"${APT[@]}" install --no-install-recommends "${PACKAGES[@]}"
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen >/dev/null
update-locale LANG=en_US.UTF-8
log "Packages installed."

# -----------------------------------------------------------------------------
phase "2/8 Vendor repositories"
# -----------------------------------------------------------------------------
CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME}")
NEED_INSTALL=()
if ! command -v tailscale >/dev/null 2>&1; then
    apt_add_repo tailscale "${TAILSCALE_APT_URL}/${CODENAME}.noarmor.gpg" "${TAILSCALE_APT_KEY_FPR}" \
        "${TAILSCALE_APT_URL}" "${CODENAME}" main
    NEED_INSTALL+=(tailscale)
fi
if ! command -v mise >/dev/null 2>&1; then
    apt_add_repo mise "${MISE_APT_KEY_URL}" "${MISE_APT_KEY_FPR}" "${MISE_APT_URL}" stable main
    NEED_INSTALL+=(mise)
fi
if [ ${#NEED_INSTALL[@]} -gt 0 ]; then
    "${APT[@]}" update
    "${APT[@]}" install --no-install-recommends "${NEED_INSTALL[@]}"
fi
systemctl enable --now tailscaled >/dev/null 2>&1 || die "tailscaled failed to start: journalctl -u tailscaled"
# Ubuntu's unattended-upgrades only follows its own pockets by default; let
# it patch the vendor repos too.
write_atomic /etc/apt/apt.conf.d/52devbox-unattended-upgrades 0644 <<'CONF'
// Managed by devbox setup.sh: keep Tailscale and mise patched automatically.
Unattended-Upgrade::Origins-Pattern {
    "origin=Tailscale";
    "origin=mise repository";
};
CONF
write_atomic /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
log "tailscale $(tailscale version | head -n1), $(mise --version | cut -d' ' -f1)"

# -----------------------------------------------------------------------------
phase "3/8 Tailscale"
# -----------------------------------------------------------------------------
TAILSCALE_IP="$(tailscale_ip)"
if [ -z "${TAILSCALE_IP}" ]; then
    if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
        keyfile=$(mktemp)
        printf '%s' "${TAILSCALE_AUTHKEY}" >"${keyfile}"
        tailscale up --auth-key="file:${keyfile}" "${TS_UP_ARGS[@]}" || { rm -f "${keyfile}"; die "tailscale up failed."; }
        rm -f "${keyfile}"
    elif ! ${OPT_YES}; then
        info "Open the login URL below to add this machine to your tailnet."
        tailscale up "${TS_UP_ARGS[@]}" || die "tailscale up failed."
    fi
    if [ -n "${TAILSCALE_AUTHKEY:-}" ] || ! ${OPT_YES}; then
        for _ in $(seq 1 30); do
            TAILSCALE_IP="$(tailscale_ip)"
            [ -n "${TAILSCALE_IP}" ] && break
            sleep 1
        done
    fi
fi
if [ -z "${TAILSCALE_IP}" ]; then
    [ "${DEVBOX_ALLOW_NO_TAILSCALE:-false}" = true ] || die "Tailscale has no IPv4 address."
    TAILSCALE_IP=127.0.0.1
    warn "Binding services to 127.0.0.1 (DEVBOX_ALLOW_NO_TAILSCALE=true)."
fi
log "Services will bind to ${TAILSCALE_IP}."

# -----------------------------------------------------------------------------
phase "4/8 Operator user"
# -----------------------------------------------------------------------------
DEV_PASSWORD=""
if ! ${USER_EXISTS}; then
    useradd -m -s /bin/zsh "${NEW_USER}"
    DEV_PASSWORD="$(generate_secret 24)"
    printf '%s:%s\n' "${NEW_USER}" "${DEV_PASSWORD}" | chpasswd
    log "Created ${NEW_USER}."
fi
usermod -aG sudo,docker "${NEW_USER}"
OP_GROUP="$(id -gn "${NEW_USER}")"
install -d -m 0755 -o root -g root /etc/devbox
printf '%s\n' "${NEW_USER}" | write_atomic "${OPERATOR_FILE}" 0644

# Convenience only, not a privilege boundary: docker group membership is
# already root-equivalent (docs/security.md). Everything else needs the
# password through the sudo group.
SUDOERS_FILE="/etc/sudoers.d/90-${NEW_USER}"
snapshot "${SUDOERS_FILE}"
write_atomic "${SUDOERS_FILE}" 0440 <<EOF
# Managed by devbox setup.sh. Passwordless convenience for the helpers in
# ~/docker (htb-vpn, exegol-start, security-check). Not a security boundary.
${NEW_USER} ALL=(root) NOPASSWD: /usr/sbin/ufw, /usr/bin/tailscale, /usr/sbin/openvpn, /usr/sbin/sshd -T
${NEW_USER} ALL=(root) NOPASSWD: /usr/bin/pkill -F /run/devbox/htb-vpn.pid openvpn
EOF
visudo -cq -f "${SUDOERS_FILE}" || { rm -f "${SUDOERS_FILE}"; die "Generated sudoers file failed visudo."; }

# PID/log directory for htb-vpn, recreated on every boot.
write_atomic /etc/tmpfiles.d/devbox.conf 0644 <<EOF
d /run/devbox 0755 ${NEW_USER} ${OP_GROUP} -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/devbox.conf

install -d -m 0700 -o "${NEW_USER}" -g "${OP_GROUP}" "${TARGET_HOME}/.ssh"
AUTH_KEYS="${TARGET_HOME}/.ssh/authorized_keys"
[ -f "${AUTH_KEYS}" ] || install -m 0600 -o "${NEW_USER}" -g "${OP_GROUP}" /dev/null "${AUTH_KEYS}"
if [ -n "${SSH_KEY}" ] && ! grep -qxF "${SSH_KEY}" "${AUTH_KEYS}"; then
    printf '%s\n' "${SSH_KEY}" >>"${AUTH_KEYS}"
    log "Added SSH key to ${AUTH_KEYS}."
fi
for d in .config .config/devbox .local .local/share .local/share/devbox projects htb; do
    [ -d "${TARGET_HOME}/${d}" ] || install -d -m 0755 -o "${NEW_USER}" -g "${OP_GROUP}" "${TARGET_HOME}/${d}"
done
# An interrupted older setup.sh could leave these root-owned in the
# operator's home, breaking mise, git and nvim for them.
# Never follow symlinks here: root must not chown a target the user chose.
for d in .config .config/mise .local .local/share .local/state .cache; do
    p="${TARGET_HOME}/${d}"
    if [ -L "${p}" ] || [ -L "$(dirname "${p}")" ] || [ ! -d "${p}" ]; then
        continue
    fi
    if [ "$(stat -c %u "${p}")" = 0 ]; then chown -h "${NEW_USER}:${OP_GROUP}" "${p}"; fi
done
chmod 0700 "${DEVBOX_CONFIG_DIR}"

# -----------------------------------------------------------------------------
phase "5/8 Docker"
# -----------------------------------------------------------------------------
# Rotate container logs host-wide (covers Exegol too). Operator-chosen log
# settings are left alone.
DAEMON_JSON=/etc/docker/daemon.json
current='{}'
[ -s "${DAEMON_JSON}" ] && current=$(cat "${DAEMON_JSON}")
if ! jq -e 'has("log-driver") or has("log-opts")' <<<"${current}" >/dev/null; then
    snapshot "${DAEMON_JSON}"
    jq '. + {"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' <<<"${current}" \
        | write_atomic "${DAEMON_JSON}" 0644
    systemctl restart docker
    log "Docker log rotation defaults set (json-file, 10m x 3)."
fi

# Let Docker bind the Tailscale IP before tailscale0 is up at boot.
write_atomic /etc/sysctl.d/60-devbox.conf 0644 <<'EOF'
# devbox: containers publish on the Tailscale IP, which may not exist yet
# when Docker starts at boot.
net.ipv4.ip_nonlocal_bind = 1
EOF
sysctl -q -p /etc/sysctl.d/60-devbox.conf

docker network inspect proxy-net >/dev/null 2>&1 || docker network create proxy-net >/dev/null
log "Docker ready."

# -----------------------------------------------------------------------------
phase "6/8 Developer environment"
# -----------------------------------------------------------------------------
if ${OPT_DEV_TOOLS}; then
    install -d -m 0755 /etc/mise
    install -m 0644 "${REPO_DIR}/scripts/install/mise-config.toml" /etc/mise/config.toml
    install -m 0644 "${REPO_DIR}/scripts/install/mise-profile.sh" /etc/profile.d/mise.sh
    # uv first: the pypi backend (exegol) installs through it.
    if as_user mise install --yes uv && as_user mise install --yes; then
        log "mise toolchain installed."
    else
        warn "mise install failed (GitHub rate limit? export MISE_GITHUB_TOKEN). Re-run setup.sh."
        FAILED_STEPS+=("mise install")
    fi

    if [ ! -d "${TARGET_HOME}/.oh-my-zsh" ]; then
        if as_user git init -q "${TARGET_HOME}/.oh-my-zsh" \
            && as_user git -C "${TARGET_HOME}/.oh-my-zsh" fetch -q --depth 1 "${OHMYZSH_REPO}" "${OHMYZSH_COMMIT}" \
            && as_user git -C "${TARGET_HOME}/.oh-my-zsh" checkout -q -B master FETCH_HEAD; then
            log "Oh My Zsh installed at ${OHMYZSH_COMMIT:0:12}."
        else
            rm -rf "${TARGET_HOME}/.oh-my-zsh"
            warn "Oh My Zsh install failed."
            FAILED_STEPS+=("oh-my-zsh")
        fi
    fi

    if [ ! -d "${TARGET_HOME}/.config/nvim" ]; then
        if as_user git clone -q --depth 1 "${LAZYVIM_STARTER_REPO}" "${TARGET_HOME}/.config/nvim"; then
            rm -rf "${TARGET_HOME}/.config/nvim/.git"
            log "LazyVim starter installed."
        else
            warn "LazyVim starter clone failed."
            FAILED_STEPS+=("lazyvim")
        fi
    fi

    # Replace .zshrc only when it is ours (marker on line 1) or absent.
    ZSHRC="${TARGET_HOME}/.zshrc"
    if [ ! -f "${ZSHRC}" ] || head -n1 "${ZSHRC}" | grep -qE '^# DevBox( v3)? — dev user \.zshrc' \
        || [ "${DEVBOX_FORCE_ZSHRC:-false}" = true ]; then
        snapshot "${ZSHRC}"
        install -m 0644 -o "${NEW_USER}" -g "${OP_GROUP}" "${REPO_DIR}/scripts/install/dev-zshrc" "${ZSHRC}"
        log "Installed ${ZSHRC}."
    else
        warn "${ZSHRC} is user-authored; left untouched (DEVBOX_FORCE_ZSHRC=true replaces it)."
    fi
else
    info "Skipped (--no-dev-tools)."
fi

# -----------------------------------------------------------------------------
phase "7/8 Stack"
# -----------------------------------------------------------------------------
install -d -m 0755 -o "${NEW_USER}" -g "${OP_GROUP}" "${DEVBOX_HOME}" "${DEVBOX_HOME}/lib" "${DEVBOX_HOME}/systemd"
install -d -m 0700 -o "${NEW_USER}" -g "${OP_GROUP}" "${DEVBOX_HOME}/exegol-workspace"
install -d -m 0700 -o "${NEW_USER}" -g "${OP_GROUP}" "${DEVBOX_SECRETS_DIR}"

install -m 0644 "${REPO_DIR}/scripts/lib/devbox-contract.sh" "${DEVBOX_HOME}/lib/devbox-contract.sh"
install -m 0644 "${REPO_DIR}/scripts/lib/devbox-lib.sh" "${DEVBOX_HOME}/lib/devbox-lib.sh"
write_atomic "${DEVBOX_HOME}/lib/.devbox-marker" 0644 <<EOF
# Devbox install marker. Do not edit: with lib/devbox-contract.sh it marks
# this tree as a devbox install, enabling upgrade-in-place.
DEVBOX_INSTALL_VERSION=1
DEVBOX_CONTRACT_VERSION=${DEVBOX_CONTRACT_VERSION}
DEVBOX_INSTALL_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DEVBOX_INSTALL_REPO=${REPO_DIR}
EOF

for svc in "${DEVBOX_SERVICES[@]}"; do
    rsync_install "${REPO_DIR}/services/${svc}" "${DEVBOX_HOME}/${svc}"
done
for f in "${RETIRED_HELPERS[@]}"; do rm -f "${DEVBOX_HOME:?}/${f}"; done
rsync -a --include="*.sh" --exclude="*" "${REPO_DIR}/scripts/host/" "${DEVBOX_HOME}/"
chmod 0755 "${DEVBOX_HOME}"/*.sh
rsync -a --delete --chmod=D0755,F0644 --include="*.template" --exclude="*" "${REPO_DIR}/scripts/systemd/" "${DEVBOX_HOME}/systemd/"

# Credentials are generated once and persisted; the htpasswd middlewares are
# re-rendered from them on every run, so the two can never diverge.
DASHBOARD_CRED="${DEVBOX_SECRETS_DIR}/traefik-dashboard.txt"
OLLAMA_CRED="${DEVBOX_SECRETS_DIR}/ollama-auth.txt"
ensure_credential "${DASHBOARD_CRED}" admin
ensure_credential "${OLLAMA_CRED}" ollama
render_basic_auth dashboard-auth "${DASHBOARD_CRED}" "${DEVBOX_HOME}/traefik/dynamic/dashboard-auth.yml"
render_basic_auth ollama-auth "${OLLAMA_CRED}" "${DEVBOX_HOME}/traefik/dynamic/ollama-auth.yml"
if [ -n "${DEV_PASSWORD}" ]; then
    printf '%s:%s\n' "${NEW_USER}" "${DEV_PASSWORD}" | write_atomic "${DEVBOX_SECRETS_DIR}/user-password.txt" 0600
fi

OWUI_ENV="${DEVBOX_HOME}/ollama-openwebui/.env"
WEBUI_SECRET_KEY="$(generate_secret 48)" ENABLE_SIGNUP=true \
    render_once "${REPO_DIR}/services/ollama-openwebui/.env.template" "${OWUI_ENV}" '$WEBUI_SECRET_KEY $ENABLE_SIGNUP'
CPUS=$(nproc)
env_default "${OWUI_ENV}" OLLAMA_CPUS "$(( CPUS < 4 ? CPUS : 4 ))"

TRAEFIK_ENV="${DEVBOX_HOME}/traefik/.env"
# Older installs kept OVH credentials in traefik/.env; they now live in traefik/ovh.env.
env_unset "${TRAEFIK_ENV}" OVH_ENDPOINT OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY
env_set "${TRAEFIK_ENV}" TAILSCALE_IP "${TAILSCALE_IP}"
env_set "${TRAEFIK_ENV}" DEVBOX_GID "$(id -g "${NEW_USER}")"

if [ "${ENABLE_HTTPS}" = true ]; then
    ACME_EMAIL="${ACME_EMAIL}" render_template "${REPO_DIR}/services/traefik/traefik.https.yml.template" \
        "${DEVBOX_HOME}/traefik/traefik.yml" '$ACME_EMAIL' 0644
    {
        for k in OVH_ENDPOINT OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY; do
            printf '%s=%s\n' "${k}" "$(env_get "${OVH_ENV_SRC}" "${k}")"
        done
    } | write_atomic "${DEVBOX_HOME}/traefik/ovh.env" 0600
    if [ "${OVH_ENV_SRC}" != "${DEVBOX_CONFIG_DIR}/ovh.env" ]; then
        install -m 0600 -o "${NEW_USER}" -g "${OP_GROUP}" "${OVH_ENV_SRC}" "${DEVBOX_CONFIG_DIR}/ovh.env"
    fi
    env_set "${OWUI_ENV}" DOMAIN "${DOMAIN}"
else
    rm -f "${DEVBOX_HOME}/traefik/ovh.env"
fi

# Static config is a bind-mounted file Compose cannot see change; a label
# carrying its hash makes `up -d` recreate Traefik when it does.
env_set "${TRAEFIK_ENV}" TRAEFIK_CONFIG_HASH "$(sha256sum "${DEVBOX_HOME}/traefik/traefik.yml" | cut -c1-16)"

for svc in "${DEVBOX_SERVICES[@]}"; do
    env_set "${DEVBOX_HOME}/${svc}/.env" COMPOSE_FILE \
        "$(compose_file_chain "${REPO_DIR}/services/${svc}" "${ENABLE_HTTPS}" "${GPU}")"
done

# Upsert the keys setup.sh owns; operator keys (BACKUP_GPG_RECIPIENT, ...) stay.
snapshot "${DEVBOX_CONFIG}"
if [ ! -s "${DEVBOX_CONFIG}" ]; then
    printf '%s\n' "# devbox install config. setup.sh manages the keys it writes and reuses them" \
        "# as defaults on re-runs (environment variables override). Add your own keys freely." \
        | write_atomic "${DEVBOX_CONFIG}" 0600
fi
for kv in "DEVBOX_USER=${NEW_USER}" "SSH_PORT=${SSH_PORT}" "ENABLE_HTTPS=${ENABLE_HTTPS}" "DOMAIN=${DOMAIN}" \
    "ACME_EMAIL=${ACME_EMAIL}" "GPU=${GPU}" "TAILSCALE_IP=${TAILSCALE_IP}"; do
    env_set "${DEVBOX_CONFIG}" "${kv%%=*}" "${kv#*=}"
done

# Ownership: everything setup.sh manages under the operator's home. The
# Exegol workspace is container-written and can be large; only its root.
chown "${NEW_USER}:${OP_GROUP}" "${DEVBOX_HOME}" "${DEVBOX_HOME}"/*.sh "${DEVBOX_HOME}/exegol-workspace"
chown -R "${NEW_USER}:${OP_GROUP}" "${DEVBOX_HOME}/lib" "${DEVBOX_HOME}/systemd" "${DEVBOX_SECRETS_DIR}" \
    "${DEVBOX_CONFIG_DIR}" "${TARGET_HOME}/.local/share/devbox"
for svc in "${DEVBOX_SERVICES[@]}"; do chown -R "${NEW_USER}:${OP_GROUP}" "${DEVBOX_HOME}/${svc}"; done
log "Stack installed to ${DEVBOX_HOME}."

# -----------------------------------------------------------------------------
phase "8/8 SSH, fail2ban, firewall"
# -----------------------------------------------------------------------------
restart_sshd() {
    systemctl daemon-reload
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        # Socket activation (Ubuntu >= 22.10): the generator rebuilds the
        # listener from sshd_config on daemon-reload; restart the socket.
        systemctl stop ssh.service 2>/dev/null || true
        systemctl restart ssh.socket
    else
        systemctl restart ssh.service
    fi
}

# Rollback restores exactly what was there: our drop-in and, on upgrades,
# the legacy one this phase replaces.
SSHD_PREVIOUS="" LEGACY_PREVIOUS=""
[ -f "${SSHD_DROPIN}" ] && SSHD_PREVIOUS=$(cat "${SSHD_DROPIN}")
if [ -f "${SSHD_LEGACY_DROPIN}" ] && grep -q '^# DevBox SSH Hardening' "${SSHD_LEGACY_DROPIN}"; then
    LEGACY_PREVIOUS=$(cat "${SSHD_LEGACY_DROPIN}")
fi
rollback_sshd() {
    if [ -n "${SSHD_PREVIOUS}" ]; then
        printf '%s\n' "${SSHD_PREVIOUS}" | write_atomic "${SSHD_DROPIN}" 0644
    else
        rm -f "${SSHD_DROPIN}"
    fi
    if [ -n "${LEGACY_PREVIOUS}" ]; then
        printf '%s\n' "${LEGACY_PREVIOUS}" | write_atomic "${SSHD_LEGACY_DROPIN}" 0644
    fi
    restart_sshd || true
}

if [ -n "${LEGACY_PREVIOUS}" ]; then
    snapshot "${SSHD_LEGACY_DROPIN}"
    rm -f "${SSHD_LEGACY_DROPIN}"
fi
snapshot "${SSHD_DROPIN}"
# sshd keeps the first value it reads for most keywords, and sshd_config
# includes sshd_config.d/*.conf in lexical order: 00- wins over cloud-init's
# 50-cloud-init.conf (which often sets PasswordAuthentication yes).
write_atomic "${SSHD_DROPIN}" 0644 <<EOF
# Managed by devbox setup.sh.
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
EOF
install -d -m 0755 /run/sshd
if ! sshd -t; then
    rollback_sshd
    die "sshd rejected ${SSHD_DROPIN}; previous configuration restored."
fi
EFFECTIVE=$(sshd -T)
for want in "port ${SSH_PORT}" "passwordauthentication no" "permitrootlogin no" "kbdinteractiveauthentication no"; do
    if ! grep -qx "${want}" <<<"${EFFECTIVE}"; then
        rollback_sshd
        die "Effective sshd config lacks '${want}'. Another file overrides it: $(grep -ilE '^(Port|PasswordAuthentication|PermitRootLogin)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf | tr '\n' ' ')"
    fi
done
if ! restart_sshd || ! wait_for_listen "${SSH_PORT}" 15 '"(sshd|systemd)"'; then
    rollback_sshd
    die "sshd is not listening on ${SSH_PORT}; previous configuration restored, firewall untouched."
fi
log "sshd listening on ${SSH_PORT}, key-only."

write_atomic /etc/fail2ban/jail.d/devbox.conf 0644 <<EOF
# Managed by devbox setup.sh.
[sshd]
enabled = true
port    = ${SSH_PORT}
backend = systemd
EOF
if systemctl restart fail2ban && systemctl is-active --quiet fail2ban; then
    log "fail2ban sshd jail on port ${SSH_PORT}."
else
    warn "fail2ban failed to start: journalctl -u fail2ban"
    FAILED_STEPS+=("fail2ban")
fi

# Converge: defaults + the SSH rule (tagged devbox-ssh). Other rules (Exegol
# noVNC ports, your own) survive; foreign rules are only removed when you
# answer yes interactively.
converge_ufw() {
    local old
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow "${SSH_PORT}/tcp" comment devbox-ssh >/dev/null
    for old in $(ufw status | awk '/# devbox-ssh/ { split($1, p, "/"); print p[1] }' | sort -u); do
        [ "${old}" = "${SSH_PORT}" ] || ufw delete allow "${old}/tcp" >/dev/null
    done
    ufw --force enable >/dev/null
    log "UFW: deny incoming, allow ${SSH_PORT}/tcp."
}
foreign=$(ufw show added 2>/dev/null | grep '^ufw ' | grep -vE "comment '(devbox-ssh|SSH|exegol-novnc-[^']*)'" || true)
if [ -n "${foreign}" ]; then
    printf 'UFW rules devbox did not create:\n%s\n' "${foreign}"
    reply=n
    ${OPT_YES} || read -r -p "Reset UFW, removing them? [y/N] " reply
    if [[ "${reply}" =~ ^[Yy]$ ]]; then
        ufw --force reset >/dev/null
    else
        warn "Kept the rules above; review them with: sudo ufw status numbered"
    fi
fi
converge_ufw

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
cat <<SUMMARY

Setup finished in $(( $(date +%s) - START_TIME ))s.

Credentials (mode 0600, owned by ${NEW_USER}):
  ${DASHBOARD_CRED}     Traefik dashboard
  ${OLLAMA_CRED}            Ollama API (external clients)
$( [ -n "${DEV_PASSWORD}" ] && echo "  ${DEVBOX_SECRETS_DIR}/user-password.txt         sudo password for ${NEW_USER}: store it, then delete the file" )

Next steps:
  1. From a NEW terminal, before closing this one:
       ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP:-<server-ip>}
  2. Start the stack (as ${NEW_USER}):  ~/docker/start-all.sh
     Start on boot:                      sudo ~/docker/install-systemd.sh
  3. On each client, resolve the hosts to ${TAILSCALE_IP}:
       ${TAILSCALE_IP}  ai.internal traefik.internal ollama.internal exegol.internal
$( [ "${ENABLE_HTTPS}" = true ] && echo "     or add a DNS record *.${DOMAIN} -> ${TAILSCALE_IP} and use https://ai.${DOMAIN}" )
  4. Create the Open WebUI admin at http://ai.internal (the first account becomes
     admin), then turn off sign-ups in Admin Panel > Settings > General.
  5. Verify: ~/docker/security-check.sh
SUMMARY

if [ ${#FAILED_STEPS[@]} -gt 0 ]; then
    warn "Completed with failures: ${FAILED_STEPS[*]}. Fix and re-run setup.sh."
    exit 1
fi
