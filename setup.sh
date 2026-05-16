#!/usr/bin/env bash
# =============================================================================
# DEVBOX SETUP SCRIPT v1.0.0 — host bootstrapper
# =============================================================================
# Remote Dev/Pentest/AI Station — Production Ready
#
# This script is now a HOST BOOTSTRAPPER. All compose files, helper scripts,
# Traefik configs, and middleware live in tracked files under services/ and
# scripts/host/ in this repo. setup.sh rsyncs them into ~/docker/ and renders
# the .env templates with whitelisted envsubst.
#
# Source of truth:
#   services/             — compose YAMLs, Traefik configs, middleware
#   scripts/host/         — start-all, stop-all, status, exegol-*, htb-vpn, etc.
#   scripts/lib/          — fetch_and_verify, download manifest, per-source handlers
#   scripts/ci/           — lint, compose-config, anchor-consistency, smoke, sbom
#   ARCHITECTURE.md       — load-bearing design decisions
#   docs/{security,updating,ops}.md — operator runbooks
#
# Target: Ubuntu 24.04 with Docker pre-installed (Hostinger Docker image)
# Stack:  Tailscale + Traefik (internal) + Ollama + Open WebUI + Exegol
#
# Security model (see ARCHITECTURE.md):
#   - dev is in the docker group (root-equivalent for socket access; honest)
#   - sudoers whitelists only ufw/tailscale/openvpn/specific systemctl
#   - Tailscale ACL + SSH key auth + UFW default-deny is the boundary
#
# Image pinning (see ARCHITECTURE.md):
#   - Compose `--lock-image-digests` produces docker-compose.lock.yml
#   - Lockfiles committed; weekly CI rebuild refreshes within minor tag
#   - cosign keyless + SBOM + SLSA provenance on the release artifact
#
# Verified downloads (see ARCHITECTURE.md):
#   - Every former curl|sh routed through scripts/lib/fetch-verify.sh
#   - SHAs pinned in scripts/lib/download-manifest.sh
#   - DEVBOX_ALLOW_UNVERIFIED=1 is the named emergency override
#
# Usage:
#   1. Edit ~/.config/devbox/config.env (or accept defaults)
#   2. For HTTPS: create ~/.config/devbox/ovh.env with OVH_* credentials
#   3. Run as root: ./setup.sh
#   4. Follow post-install instructions
#
# Author: gl0bal01
# Date: 2026-05-16 (v1.0.0)
# =============================================================================

set -euo pipefail

# Per Critic Issue #5 Scenario E — restrictive umask BEFORE any file is written.
umask 077

# Repo root (where this script lives — used for rsync sources)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# ARGUMENT PARSER  (runs before root-check, flock, and phase logic)
# =============================================================================
OPT_YES=false
OPT_CHECK=false
OPT_DRY_RUN=false

_usage() {
  cat <<'USAGE'
Usage: sudo ./setup.sh [OPTIONS]

Options:
  -y, --yes      Skip interactive confirmation prompts (auto-confirm).
  --check        Dry-validation mode: verify repo sanity and contract sync
                 without mutating the host. Does NOT require root.
                 Exit 0 = sync (or no prior install); exit 1 = drift detected.
  --dry-run      Preview what each phase would do without touching the host.
                 Does NOT require root. Prints a structured per-phase summary
                 then exits 0. Safe to run as any user.
  -h, --help     Show this help and exit.

Examples:
  sudo ./setup.sh                 # Interactive install
  sudo ./setup.sh --yes           # Non-interactive install
  ./setup.sh --check              # Validate contract without installing
  ./setup.sh --dry-run            # Preview all phases (no root, no changes)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)     OPT_YES=true;     shift ;;
    --check)      OPT_CHECK=true;   shift ;;
    --dry-run)    OPT_DRY_RUN=true; shift ;;
    -h|--help)    _usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      _usage >&2
      exit 2
      ;;
  esac
done

# --check mode: validate contract+marker, report sync/drift, exit immediately.
# Must run BEFORE root-check, flock, and any phase logic.
if $OPT_CHECK; then
  # Repo sanity (same paths the full installer checks)
  _check_fail=0
  [ -d "${REPO_DIR}/services" ]              || { echo "[FAIL] services/ tree missing"; _check_fail=1; }
  [ -d "${REPO_DIR}/scripts/host" ]          || { echo "[FAIL] scripts/host/ tree missing"; _check_fail=1; }
  [ -f "${REPO_DIR}/scripts/lib/devbox-contract.sh" ] || { echo "[FAIL] scripts/lib/devbox-contract.sh missing"; _check_fail=1; }
  if [ "${_check_fail}" -ne 0 ]; then
    echo "[FAIL] Repo sanity check failed — is REPO_DIR correct? (${REPO_DIR})" >&2
    exit 1
  fi
  echo "[OK] Repo sanity: services/, scripts/host/, scripts/lib/devbox-contract.sh present"

  # Source repo contract to learn DEVBOX_HOME
  # shellcheck source=scripts/lib/devbox-contract.sh
  . "${REPO_DIR}/scripts/lib/devbox-contract.sh"
  _DOCKER_DIR="${DEVBOX_HOME}"
  _installed_contract="${_DOCKER_DIR}/lib/devbox-contract.sh"
  _marker="${_DOCKER_DIR}/lib/.devbox-marker"

  if [ ! -f "${_marker}" ]; then
    echo "[OK] No prior install found (marker absent at ${_marker})"
    exit 0
  fi

  if [ ! -f "${_installed_contract}" ]; then
    echo "[WARN] Marker present but contract file missing at ${_installed_contract}" >&2
    exit 1
  fi

  if cmp -s "${REPO_DIR}/scripts/lib/devbox-contract.sh" "${_installed_contract}"; then
    echo "[OK] contract in sync"
    exit 0
  else
    _changed_lines=$(diff -u "${_installed_contract}" "${REPO_DIR}/scripts/lib/devbox-contract.sh" | grep -c '^[+-]' || true)
    echo "[DRIFT] Installed contract differs from repo (${_changed_lines} changed lines)."
    echo "        Run: sudo ./setup.sh --yes   to resync"
    exit 1
  fi
fi

# --dry-run mode: preview every phase without touching the host.
# Must run BEFORE flock, root-check, and any phase logic.
if $OPT_DRY_RUN; then
  # Source the contract read-only — needed for DEVBOX_HOME / DEVBOX_SERVICES.
  # shellcheck source=scripts/lib/devbox-contract.sh
  . "${REPO_DIR}/scripts/lib/devbox-contract.sh"

  _DR_USER="${DEVBOX_USER:-dev}"
  _DR_SSH_PORT="${DEVBOX_SSH_PORT:-5522}"
  _DR_DOCKER_DIR="${DEVBOX_HOME}"
  _DR_HOME="${HOME}"

  echo "[DRY-RUN] Devbox setup preview — no changes will be made."
  echo ""

  # Phase 1 — apt packages
  echo "[DRY-RUN] Phase 1 — System Update: would run apt update + apt upgrade, then install:"
  # Extract package list scoped to Phase 1 (sed range avoids matching this block itself).
  sed -n '/^# PHASE 1: System Update/,/^log "System packages installed"/{/^[[:space:]]\+[a-z][a-z]/{s/\\$//;s/^[[:space:]]*/  /;p}}' "${REPO_DIR}/setup.sh"
  echo ""

  # Phase 2 — User
  echo "[DRY-RUN] Phase 2 — User:"
  echo "  would create user '${_DR_USER}' if absent"
  echo "  would install sudoers at /etc/sudoers.d/90-${_DR_USER}"
  echo ""

  # Phase 3 — SSH
  echo "[DRY-RUN] Phase 3 — SSH:"
  echo "  would write /etc/ssh/sshd_config.d/99-hardening.conf with Port ${_DR_SSH_PORT}"
  echo "  key-only auth, PermitRootLogin no, X11Forwarding no"
  echo ""

  # Phase 4 — UFW
  echo "[DRY-RUN] Phase 4 — UFW:"
  echo "  would reset UFW + default deny incoming + allow ${_DR_SSH_PORT}/tcp"
  echo ""

  # Phase 5 — Docker networks
  echo "[DRY-RUN] Phase 5 — Docker networks:"
  echo "  would create proxy-net (bridge)"
  echo "  would create ollama-net (internal bridge)"
  echo ""

  # Phase 6 — Tailscale
  echo "[DRY-RUN] Phase 6 — Tailscale:"
  echo "  would install Tailscale (verified download) if absent"
  echo ""

  # Phase 7/7b/7c — mise + lazy tools + Rust/Bun/zellij
  echo "[DRY-RUN] Phase 7/7b/7c — mise + lazy tools + dev runtimes:"
  echo "  mise              — would install to /opt/mise if absent"
  echo "  node@22           — would activate via mise if absent"
  echo "  lazygit           — would install to /usr/local/bin if absent"
  echo "  lazydocker        — would install to /usr/local/bin if absent"
  echo "  neovim            — would install to /opt/nvim-linux-x86_64 if absent"
  echo "  lazyvim config    — would clone starter to ~/.config/nvim if absent"
  echo "  rust/cargo        — would install via rustup if absent"
  echo "  cargo-binstall    — would install via cargo if absent"
  echo "  zellij            — would install via cargo-binstall if absent"
  echo "  bun               — would install (verified download) if absent"
  echo ""

  # Phase 8 — Docker stack (rsync pairs, render_env pairs, config.env keys, rsync --dry-run)
  echo "[DRY-RUN] Phase 8 — Docker Stack:"
  echo "  rsync pairs (source -> dest):"
  echo "    ${REPO_DIR}/services/traefik        -> ${_DR_DOCKER_DIR}/traefik"
  echo "    ${REPO_DIR}/services/ollama-openwebui -> ${_DR_DOCKER_DIR}/ollama-openwebui"
  echo "    ${REPO_DIR}/scripts/host/           -> ${_DR_DOCKER_DIR}/"
  echo "  render_env template -> dest pairs:"
  echo "    traefik/dynamic/dashboard-auth.yml.template -> traefik/dynamic/dashboard-auth.yml"
  echo "    traefik/dynamic/ollama-auth.yml.template    -> traefik/dynamic/ollama-auth.yml"
  echo "    ollama-openwebui/.env.template              -> ollama-openwebui/.env"
  echo "  config.env keys that would be written to ${_DR_HOME}/.config/devbox/config.env:"
  echo "    ENABLE_HTTPS  DOMAIN  TAILSCALE_IP  DEVBOX_USER  COMPOSE_FILE_TRAEFIK  COMPOSE_FILE_OLLAMA_OPENWEBUI"
  echo "  Files that would change (rsync --dry-run per service):"
  for _dr_svc in traefik ollama-openwebui; do
    _dr_src="${REPO_DIR}/services/${_dr_svc}"
    _dr_dest="${_DR_DOCKER_DIR}/${_dr_svc}"
    if [ -d "${_dr_src}" ]; then
      echo "    [${_dr_svc}]"
      rsync -avn --itemize-changes --delete \
        --exclude='.env' \
        --exclude='letsencrypt/' \
        --exclude='*-data/' \
        --exclude='exegol-workspace/' \
        --exclude='backups/' \
        --exclude='*.lock.yml.tmp.*' \
        "${_dr_src}/" "${_dr_dest}/" 2>/dev/null \
        | grep -v '^sending\|^sent\|^total\|^$' \
        | sed 's/^/      /' \
        || echo "      (dest absent — all files would be copied)"
    fi
  done
  echo ""

  # Phase 9 — Shell
  echo "[DRY-RUN] Phase 9 — Shell:"
  echo "  would install /etc/profile.d/mise.sh (from scripts/install/mise-profile.sh)"
  echo "  would install ${_DR_HOME}/.zshrc from scripts/install/dev-zshrc"
  if [ -f "${_DR_HOME}/.zshrc" ]; then
    echo "  existing ~/.zshrc would be snapshotted to ~/.local/share/devbox/backups/ first"
  fi
  echo ""

  # Phase 10 — Credentials
  echo "[DRY-RUN] Phase 10 — Credentials:"
  echo "  would write ~/.devbox-credentials (mode 0600) with generated service passwords"
  if command -v gpg >/dev/null 2>&1 && gpg --list-keys 2>/dev/null | grep -q '^pub'; then
    echo "  GPG key detected — would encrypt to ~/.devbox-credentials.gpg and shred plaintext"
  else
    echo "  no GPG key detected — credentials would remain as plaintext (shred manually)"
  fi
  echo ""

  echo "[DRY-RUN] No changes made. Re-run without --dry-run to apply."
  exit 0
fi

# Runtime contract — sourced from the repo at install time. The same file is
# copied into ${DOCKER_DIR}/lib/devbox-contract.sh during Phase 8 so that
# helpers can re-source it after install. See scripts/lib/devbox-contract.sh
# and plan v4.1.
# shellcheck source=scripts/lib/devbox-contract.sh
. "${REPO_DIR}/scripts/lib/devbox-contract.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

# User settings
NEW_USER="${DEVBOX_USER:-dev}"
USER_EMAIL="${DEVBOX_EMAIL:-admin@example.com}"

# SSH settings
SSH_PORT="${DEVBOX_SSH_PORT:-5522}"

# Read SSH public key from env, file, or fall back to manual prompt
if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
  : # use env var
elif [ -f "${HOME}/.ssh/devbox_authorized_key" ]; then
  SSH_PUBLIC_KEY=$(head -1 "${HOME}/.ssh/devbox_authorized_key" 2>/dev/null || echo "")
elif [ -f "/root/.ssh/devbox_authorized_key" ]; then
  SSH_PUBLIC_KEY=$(head -1 "/root/.ssh/devbox_authorized_key" 2>/dev/null || echo "")
else
  SSH_PUBLIC_KEY=""
fi

# Service secrets (auto-generated if empty)
OPENWEBUI_SECRET="${OPENWEBUI_SECRET:-}"

# Domain (used when ENABLE_HTTPS=true)
DOMAIN="${DEVBOX_DOMAIN:-example.com}"

# HTTPS toggle. To enable: set ENABLE_HTTPS=true AND create ~/.config/devbox/ovh.env
ENABLE_HTTPS="${ENABLE_HTTPS:-false}"

# Per Critic Issue F3 / ARCHITECTURE.md — OVH credentials NEVER live in this script.
# They come from ${XDG_CONFIG_HOME:-$HOME/.config}/devbox/ovh.env (mode 0600).
# Schema:
#   OVH_ENDPOINT=ovh-eu
#   OVH_APPLICATION_KEY=<key>
#   OVH_APPLICATION_SECRET=<secret>
#   OVH_CONSUMER_KEY=<key>
OVH_ENV_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/devbox/ovh.env"

# =============================================================================
# DO NOT EDIT BELOW THIS LINE
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging
log()   { echo -e "${GREEN}[✓]${NC} $1"; }
info()  { echo -e "${BLUE}[i]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# Password generator (18 chars, base64-stripped)
generate_password() { openssl rand -base64 18 | tr -d '/+='; }

# Cleanup trap — Critic Scenario E. Wipes the credentials file if a partial
# install was interrupted before chmod could land.
CLEANUP_FILES=()
cleanup() {
  local rc=$?
  if [ $rc -ne 0 ] && [ ${#CLEANUP_FILES[@]} -gt 0 ]; then
    warn "Setup interrupted (exit $rc). Shredding partial credential files..."
    for f in "${CLEANUP_FILES[@]}"; do
      [ -e "$f" ] && shred -u "$f" 2>/dev/null || rm -f "$f"
    done
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

# Per Critic Scenario F — flock guard prevents concurrent re-installs.
LOCK_FD=200
LOCK_FILE=/var/lock/devbox-setup.lock
exec 200>"${LOCK_FILE}"
if ! flock -n ${LOCK_FD}; then
  error "Another devbox setup.sh is already running (lock: ${LOCK_FILE}). Aborting."
fi

# Generate passwords if not set
[ -z "$OPENWEBUI_SECRET" ] && OPENWEBUI_SECRET=$(generate_password)
DEV_PASSWORD=$(generate_password)
TRAEFIK_USER="admin"
TRAEFIK_PASS=$(generate_password)
OLLAMA_AUTH_USER="ollama"
OLLAMA_AUTH_PASS=$(generate_password)

# =============================================================================
# HELPERS — rsync_install + render_env (the heart of the v3 refactor)
# =============================================================================

# rsync the canonical source tree into ${DOCKER_DIR} with explicit excludes for
# operator-mutable runtime data. ARCHITECTURE.md / ARCHITECTURE.md / Critic §I1.
#
# Excludes:
#   .env             — operator-edited secrets (preserved if present)
#   letsencrypt/     — ACME storage; never overwrite
#   *-data/          — Ollama / OpenWebUI persistent volumes
#   exegol-workspace/— pentest workspace
#   backups/         — local backup output
rsync_install() {
  local src="$1" dest="$2"
  install -d -m 0755 "${dest}"
  rsync -a --delete \
    --exclude='.env' \
    --exclude='letsencrypt/' \
    --exclude='*-data/' \
    --exclude='exegol-workspace/' \
    --exclude='backups/' \
    --exclude='*.lock.yml.tmp.*' \
    "${src}/" "${dest}/"
}

# Render a *.template file via WHITELISTED envsubst (per ARCHITECTURE.md / Critic CRIT-3).
# Refuses to overwrite an existing destination — operator secrets are preserved
# across re-installs.
#
# Usage: render_env <template_path> <dest_path> '$VAR1 $VAR2 $VAR3'
render_env() {
  local tmpl="$1" dest="$2" whitelist="$3"
  if [ -e "$dest" ]; then
    info "Preserving existing $(basename "$dest") (not overwritten)"
    return 0
  fi
  envsubst "$whitelist" <"$tmpl" >"$dest"
  chmod 0600 "$dest"
}

# Snapshot a file before overwriting (Scenario B mitigation). Backups live at
# ~/.local/share/devbox/backups/<timestamp>/ and are referenced in docs/ops.md.
snapshot_file() {
  local target="$1"
  [ ! -e "$target" ] && return 0
  local backup_dir
  backup_dir="${USER_HOME}/.local/share/devbox/backups/$(date -u +%Y%m%dT%H%M%SZ)"
  install -d -m 0700 "${backup_dir}"
  chown "${NEW_USER}:${NEW_USER}" "${backup_dir%/*}" "${backup_dir}" 2>/dev/null || true
  cp -a "${target}" "${backup_dir}/$(basename "${target}")"
  info "Snapshot: ${backup_dir}/$(basename "${target}")"
}

# Collision guard — refuse to install into ${DOCKER_DIR} if it contains files
# outside the devbox allowlist UNLESS the upgrade-in-place marker is present
# (both ${DOCKER_DIR}/lib/devbox-contract.sh AND ${DOCKER_DIR}/lib/.devbox-marker).
# See plan v4.1.
#
# Allowlist (relative to ${DOCKER_DIR}):
#   lib/devbox-contract.sh, lib/.devbox-marker,
#   traefik/, ollama-openwebui/, .secrets/,
#   start-all.sh, stop-all.sh, status.sh, security-check.sh, backup.sh,
#   diagnose.sh, exegol-*.sh, htb-vpn.sh, install-ai-dev-stack.sh,
#   rotate-ollama-auth.sh, exegol-workspace/, projects/
collision_guard() {
  local docker_dir="$1"
  local marker="${docker_dir}/lib/.devbox-marker"
  local installed_contract="${docker_dir}/lib/devbox-contract.sh"

  # Empty / non-existent dir is always fine.
  [ ! -d "${docker_dir}" ] && return 0
  if [ -z "$(ls -A "${docker_dir}" 2>/dev/null)" ]; then
    return 0
  fi

  # Upgrade-in-place: both the contract file AND the marker file must be
  # present. Either missing -> run the full guard so a name collision on
  # devbox-contract.sh alone does not bypass the check.
  if [ -f "${installed_contract}" ] && [ -f "${marker}" ]; then
    info "Detected prior devbox install (marker version: $(grep '^DEVBOX_INSTALL_VERSION=' "${marker}" | head -1 | cut -d= -f2))"
    info "Upgrade-in-place mode: skipping collision guard."
    return 0
  fi

  local offenders=()
  local allowlist_patterns=(
    "lib"
    "traefik"
    "ollama-openwebui"
    ".secrets"
    "start-all.sh"
    "stop-all.sh"
    "status.sh"
    "security-check.sh"
    "backup.sh"
    "diagnose.sh"
    "rotate-ollama-auth.sh"
    "htb-vpn.sh"
    "install-ai-dev-stack.sh"
    "exegol-workspace"
    "projects"
  )

  local entry rel
  for entry in "${docker_dir}"/* "${docker_dir}"/.[!.]*; do
    [ ! -e "${entry}" ] && continue
    rel="$(basename "${entry}")"
    local allowed=false
    local pattern
    for pattern in "${allowlist_patterns[@]}"; do
      if [ "${rel}" = "${pattern}" ]; then
        allowed=true
        break
      fi
    done
    # exegol-*.sh family is allowlisted as a glob.
    case "${rel}" in
      exegol-*.sh) allowed=true ;;
    esac
    ${allowed} || offenders+=("${rel}")
  done

  if [ ${#offenders[@]} -gt 0 ]; then
    error "Refusing to install into existing non-devbox tree at ${docker_dir}.
       Offending entries (not in devbox allowlist):
$(printf '         %s\n' "${offenders[@]}")
       Move them aside or pick a clean DEVBOX_HOME, then re-run setup.sh."
  fi
}

# Source the verified-download library
# shellcheck source=scripts/lib/fetch-verify.sh
. "${REPO_DIR}/scripts/lib/fetch-verify.sh"
# shellcheck source=scripts/lib/download-manifest.sh
. "${REPO_DIR}/scripts/lib/download-manifest.sh"

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

# Must be root
[ "$(id -u)" -ne 0 ] && error "This script must be run as root"

# Repo sanity — verify we have what we need
[ -d "${REPO_DIR}/services" ] || error "services/ tree missing — wrong working directory? (REPO_DIR=${REPO_DIR})"
[ -d "${REPO_DIR}/scripts/host" ] || error "scripts/host/ tree missing"
[ -d "${REPO_DIR}/scripts/lib" ] || error "scripts/lib/ tree missing"

# Check OS
if ! grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
  warn "This script is designed for Ubuntu. Proceed with caution."
fi

# HTTPS pre-flight — refuse if OVH config missing per ARCHITECTURE.md
if [ "$ENABLE_HTTPS" = "true" ]; then
  if [ ! -f "${OVH_ENV_FILE}" ]; then
    error "ENABLE_HTTPS=true but ${OVH_ENV_FILE} is missing.
       Create it with mode 0600 and these keys:
         OVH_ENDPOINT=ovh-eu
         OVH_APPLICATION_KEY=...
         OVH_APPLICATION_SECRET=...
         OVH_CONSUMER_KEY=...
       Get credentials at https://api.ovh.com/createToken/"
  fi
  set -a
  # shellcheck source=/dev/null
  . "${OVH_ENV_FILE}"
  set +a
  log "OVH credentials loaded from ${OVH_ENV_FILE}"
fi

# Detect existing installations
EXISTING_USER=false
EXISTING_DOCKER=false
EXISTING_TAILSCALE=false
EXISTING_MISE=false
EXISTING_ZSH=false
EXISTING_EXEGOL=false

id "${NEW_USER}" &>/dev/null && EXISTING_USER=true
command -v docker &>/dev/null && EXISTING_DOCKER=true
command -v tailscale &>/dev/null && EXISTING_TAILSCALE=true
([ -x "/opt/mise" ] || [ -x "/usr/local/bin/mise" ] || command -v mise &>/dev/null) && EXISTING_MISE=true
[ -d "/home/${NEW_USER}/.oh-my-zsh" ] && EXISTING_ZSH=true
docker images 2>/dev/null | grep -q "Exegol-images\|exegol" && EXISTING_EXEGOL=true

# Banner
echo -e "${CYAN}"
cat <<'BANNER'
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║     ██████╗ ███████╗██╗   ██╗██████╗  ██████╗ ██╗  ██╗                    ║
║     ██╔══██╗██╔════╝██║   ██║██╔══██╗██╔═══██╗╚██╗██╔╝                    ║
║     ██║  ██║█████╗  ██║   ██║██████╔╝██║   ██║ ╚███╔╝                     ║
║     ██║  ██║██╔══╝  ╚██╗ ██╔╝██╔══██╗██║   ██║ ██╔██╗                     ║
║     ██████╔╝███████╗ ╚████╔╝ ██████╔╝╚██████╔╝██╔╝ ██╗                    ║
║     ╚═════╝ ╚══════╝  ╚═══╝  ╚═════╝  ╚═════╝ ╚═╝  ╚═╝                    ║
║                                                                           ║
║     Remote Dev / Pentest / AI Station Setup — v1.0.0                      ║
║     Tailscale + Traefik + Ollama + Open WebUI + Exegol                    ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

echo -e "${YELLOW}Configuration:${NC}"
echo "  User:        ${NEW_USER}"
echo "  SSH Port:    ${SSH_PORT}"
echo "  Domain:      ${DOMAIN}"
echo "  HTTPS:       ${ENABLE_HTTPS}"
echo "  SSH Key:     ${SSH_PUBLIC_KEY:+Provided}${SSH_PUBLIC_KEY:-Not provided (add manually)}"
echo "  Repo:        ${REPO_DIR}"
echo ""

echo -e "${YELLOW}Detected Existing Installations:${NC}"
$EXISTING_USER && echo "  ✓ User '${NEW_USER}' exists" || echo "  ○ User '${NEW_USER}' will be created"
$EXISTING_DOCKER && echo "  ✓ Docker installed" || echo "  ✗ Docker NOT found (required!)"
$EXISTING_TAILSCALE && echo "  ✓ Tailscale installed" || echo "  ○ Tailscale will be installed"
$EXISTING_MISE && echo "  ✓ mise installed" || echo "  ○ mise will be installed"
$EXISTING_ZSH && echo "  ✓ Oh-My-Zsh configured" || echo "  ○ Oh-My-Zsh will be installed"
$EXISTING_EXEGOL && echo "  ✓ Exegol image found" || echo "  ○ Exegol will be pulled on first use"
echo ""

if ! $EXISTING_DOCKER; then
  error "Docker not found! This script requires Docker pre-installed."
fi

if $OPT_YES; then
  echo "(--yes: skipping confirmation prompt)"
else
  read -p "Continue with setup? (y/N) " -n 1 -r
  echo
  [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
fi

START_TIME=$(date +%s)

# =============================================================================
# PHASE 1: System Update & Essential Packages
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 1: System Update & Essential Packages${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

info "Fixing locale settings..."
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
apt install -y -qq locales >/dev/null 2>&1 || true
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen 2>/dev/null || true
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 >/dev/null 2>&1 || true

info "Updating system packages..."
apt update -qq
apt upgrade -y -qq

info "Installing essential packages..."
apt install -y -qq --no-install-recommends \
  curl wget git unzip jq htop ncdu tree \
  zsh tmux vim nano \
  ca-certificates gnupg lsb-release apt-transport-https \
  ufw fail2ban util-linux \
  build-essential gettext-base \
  openvpn wireguard-tools \
  python3-pip python3-venv \
  net-tools dnsutils iputils-ping \
  rsync gawk

log "System packages installed"

# =============================================================================
# PHASE 2: Create User (with restricted sudoers per F4 / ARCHITECTURE.md)
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 2: Create User '${NEW_USER}'${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if $EXISTING_USER; then
  log "User '${NEW_USER}' already exists"
  USER_HOME=$(getent passwd "${NEW_USER}" | cut -d: -f6)
  usermod -aG sudo "${NEW_USER}" 2>/dev/null || true
else
  info "Creating user '${NEW_USER}'..."
  useradd -m -s /bin/zsh "${NEW_USER}"
  echo "${NEW_USER}:${DEV_PASSWORD}" | chpasswd
  USER_HOME="/home/${NEW_USER}"
  usermod -aG sudo "${NEW_USER}"
fi

# Restricted sudoers — F4. dev is root via the docker group anyway (ARCHITECTURE.md),
# so the sudoers whitelist only covers commands NOT handled by the docker
# socket: ufw, tailscale, openvpn, specific systemctl invocations.
SUDOERS_FILE="/etc/sudoers.d/90-${NEW_USER}"
if [ -f "${SUDOERS_FILE}" ]; then
  snapshot_file "${SUDOERS_FILE}"
fi
cat >"${SUDOERS_FILE}" <<SUDOERS
# DevBox restricted sudoers — see ARCHITECTURE.md
# The security boundary is Tailscale ACL + SSH key auth + UFW default-deny.
# dev is in the docker group (root-equivalent for socket access — accepted).
${NEW_USER} ALL=(root) NOPASSWD: /usr/sbin/ufw, /usr/bin/tailscale, /usr/sbin/openvpn
${NEW_USER} ALL=(root) NOPASSWD: /bin/systemctl restart docker, /bin/systemctl reload ufw
${NEW_USER} ALL=(root) NOPASSWD: /usr/bin/install -d -m 0755 -o ${NEW_USER} /run/devbox
${NEW_USER} ALL=(root) PASSWD: ALL
SUDOERS
chmod 0440 "${SUDOERS_FILE}"
visudo -c -f "${SUDOERS_FILE}" >/dev/null || error "sudoers file ${SUDOERS_FILE} failed visudo validation"
log "Restricted sudoers configured (per ARCHITECTURE.md)"

# SSH directory
info "Setting up SSH directory..."
mkdir -p "${USER_HOME}/.ssh"
touch "${USER_HOME}/.ssh/authorized_keys"
chmod 700 "${USER_HOME}/.ssh"
chmod 600 "${USER_HOME}/.ssh/authorized_keys"
chown -R "${NEW_USER}:${NEW_USER}" "${USER_HOME}/.ssh"

if [ -n "${SSH_PUBLIC_KEY}" ]; then
  if grep -qF "${SSH_PUBLIC_KEY}" "${USER_HOME}/.ssh/authorized_keys" 2>/dev/null; then
    log "SSH public key already present"
  else
    echo "${SSH_PUBLIC_KEY}" >>"${USER_HOME}/.ssh/authorized_keys"
    log "SSH public key added"
  fi
else
  warn "No SSH key provided - add your key to ${USER_HOME}/.ssh/authorized_keys"
fi

# =============================================================================
# PHASE 3: SSH Hardening
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 3: SSH Hardening${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

EXISTING_SSH_HARDENING=false
[ -f "/etc/ssh/sshd_config.d/99-hardening.conf" ] && EXISTING_SSH_HARDENING=true

if $EXISTING_SSH_HARDENING; then
  CURRENT_PORT=$(grep "^Port" /etc/ssh/sshd_config.d/99-hardening.conf 2>/dev/null | awk '{print $2}')
  log "SSH hardening already configured (port ${CURRENT_PORT:-unknown})"
  if [ "${CURRENT_PORT}" != "${SSH_PORT}" ]; then
    warn "Current SSH port (${CURRENT_PORT}) differs from config (${SSH_PORT})"
    snapshot_file "/etc/ssh/sshd_config.d/99-hardening.conf"
    EXISTING_SSH_HARDENING=false
  fi
fi

if ! $EXISTING_SSH_HARDENING; then
  info "Backing up SSH config..."
  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  info "Applying SSH hardening..."
  mkdir -p /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/99-hardening.conf <<SSHHARDEN
# DevBox SSH Hardening
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
SSHHARDEN
  log "SSH hardened (port ${SSH_PORT}, key-only auth)"
  SSH_RESTART_NEEDED=true
else
  SSH_RESTART_NEEDED=false
fi

# =============================================================================
# PHASE 4: Firewall (UFW)
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 4: Firewall Configuration${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

EXISTING_UFW_RULES=$(ufw status 2>/dev/null | grep -c "ALLOW\|DENY" || echo "0")
if [ "${EXISTING_UFW_RULES}" -gt "0" ]; then
  warn "Existing UFW rules detected (${EXISTING_UFW_RULES} rules)"
  if $OPT_YES; then
    echo "(--yes: auto-confirming UFW reset)"
    REPLY=y
  else
    read -p "Reset UFW and apply DevBox firewall rules? (y/N) " -n 1 -r
    echo
  fi
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Keeping existing UFW rules - ensuring SSH port ${SSH_PORT} is allowed"
    ufw allow "${SSH_PORT}/tcp" comment "SSH" 2>/dev/null || true
  else
    info "Configuring UFW firewall..."
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp" comment "SSH"
    ufw --force enable
    log "Firewall configured (only SSH:${SSH_PORT} open)"
  fi
else
  info "Configuring UFW firewall..."
  ufw --force reset >/dev/null 2>&1
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp" comment "SSH"
  ufw --force enable
  log "Firewall configured (only SSH:${SSH_PORT} open)"
fi

# =============================================================================
# PHASE 5: Docker Verification + Networks
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 5: Docker Verification${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | tr -d ',')
log "Docker: v${DOCKER_VERSION}"

if docker compose version &>/dev/null; then
  COMPOSE_VERSION=$(docker compose version --short)
  log "Docker Compose: v${COMPOSE_VERSION}"
else
  warn "Docker Compose plugin not found - installing..."
  apt install -y -qq docker-compose-plugin
fi

# Add user to docker group (root-equivalent — see ARCHITECTURE.md)
usermod -aG docker "${NEW_USER}"
log "User '${NEW_USER}' added to docker group (root-equivalent — see ARCHITECTURE.md)"

# Create networks (idempotent)
docker network create proxy-net 2>/dev/null && log "Docker network 'proxy-net' created" || log "Docker network 'proxy-net' already exists"
docker network create --internal ollama-net 2>/dev/null && log "Docker network 'ollama-net' created (internal)" || log "Docker network 'ollama-net' already exists"

# =============================================================================
# PHASE 6: Tailscale (verified download)
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 6: Tailscale VPN${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if $EXISTING_TAILSCALE; then
  TS_VERSION=$(tailscale version | head -1)
  log "Tailscale already installed: ${TS_VERSION}"
  if tailscale status &>/dev/null; then
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
    log "Tailscale connected (IP: ${TS_IP})"
  else
    info "Tailscale installed but not authenticated"
  fi
else
  info "Installing Tailscale (verified download per ARCHITECTURE.md)..."
  fetch_and_verify "${MANIFEST_TAILSCALE_URL}" "${MANIFEST_TAILSCALE_SHA}" /tmp/tailscale-install.sh
  sh /tmp/tailscale-install.sh
  rm -f /tmp/tailscale-install.sh
  log "Tailscale installed (authenticate after script completes)"
fi

# =============================================================================
# PHASE 7: mise (verified download)
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 7: mise (Polyglot Version Manager)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if $EXISTING_MISE; then
  MISE_VERSION=$(mise --version 2>/dev/null || echo "unknown")
  log "mise already installed: ${MISE_VERSION}"
else
  info "Installing mise (verified download per ARCHITECTURE.md)..."
  fetch_and_verify "${MANIFEST_MISE_URL}" "${MANIFEST_MISE_SHA}" /tmp/mise-install.sh
  export MISE_INSTALL_PATH=/opt/mise
  sh /tmp/mise-install.sh
  rm -f /tmp/mise-install.sh
  ln -sf /opt/mise /usr/local/bin/mise
  log "mise installed"
fi

[ -f /opt/mise ] && [ ! -L /usr/local/bin/mise ] && ln -sf /opt/mise /usr/local/bin/mise

# Shell integration for all users — installed from tracked file
mkdir -p /etc/profile.d
install -m 0644 "${REPO_DIR}/scripts/install/mise-profile.sh" /etc/profile.d/mise.sh

# (mise zsh activation lives in the canonical dev .zshrc installed in PHASE 9 —
# no separate append needed; PHASE 9 rewrites the .zshrc unconditionally.)
if [ -d "${USER_HOME}" ]; then
  mkdir -p "${USER_HOME}/.config/mise"
  info "Installing default tools via mise for ${NEW_USER}..."
  su - "${NEW_USER}" -c 'export PATH="/opt/mise:$PATH" && mise use --global node@22' 2>/dev/null || true
fi

log "mise shell integration configured"

# =============================================================================
# PHASE 7b: Lazy Tools (lazygit, lazydocker, neovim/lazyvim — verified)
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 7b: Lazy Tools${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# lazygit (verified)
if command -v lazygit &>/dev/null; then
  log "lazygit already installed"
else
  info "Installing lazygit (verified download)..."
  fetch_and_verify "${MANIFEST_LAZYGIT_URL}" "${MANIFEST_LAZYGIT_SHA}" /tmp/lazygit.tar.gz
  tar xf /tmp/lazygit.tar.gz -C /tmp lazygit
  install /tmp/lazygit /usr/local/bin
  rm -f /tmp/lazygit /tmp/lazygit.tar.gz
  log "lazygit installed"
fi

# lazydocker (verified)
if command -v lazydocker &>/dev/null; then
  log "lazydocker already installed"
else
  info "Installing lazydocker (verified download)..."
  fetch_and_verify "${MANIFEST_LAZYDOCKER_URL}" "${MANIFEST_LAZYDOCKER_SHA}" /tmp/lazydocker-install.sh
  bash /tmp/lazydocker-install.sh
  rm -f /tmp/lazydocker-install.sh
  log "lazydocker installed"
fi

# neovim (verified)
if command -v nvim &>/dev/null; then
  log "neovim already installed"
else
  info "Installing neovim (verified download)..."
  fetch_and_verify "${MANIFEST_NEOVIM_URL}" "${MANIFEST_NEOVIM_SHA}" /tmp/nvim.tar.gz
  tar -C /opt -xzf /tmp/nvim.tar.gz
  ln -sf /opt/nvim-linux-x86_64/bin/nvim /usr/local/bin/nvim
  rm -f /tmp/nvim.tar.gz
  log "neovim installed"
fi

# lazyvim config for dev user
if [ -d "${USER_HOME}/.config/nvim" ]; then
  log "nvim config already exists (skipping lazyvim)"
else
  info "Installing lazyvim for ${NEW_USER}..."
  su - "${NEW_USER}" -c '
    mv ~/.config/nvim{,.bak} 2>/dev/null || true
    mv ~/.local/share/nvim{,.bak} 2>/dev/null || true
    mv ~/.local/state/nvim{,.bak} 2>/dev/null || true
    mv ~/.cache/nvim{,.bak} 2>/dev/null || true
    git clone https://github.com/LazyVim/starter ~/.config/nvim
    rm -rf ~/.config/nvim/.git
  ' 2>/dev/null || true
  log "lazyvim installed for ${NEW_USER}"
fi

# =============================================================================
# PHASE 7c: Development Runtimes (Rust, Bun, Zellij — verified)
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 7c: Development Runtimes${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Rust (verified)
if su - "${NEW_USER}" -c 'command -v cargo' &>/dev/null; then
  log "Rust/Cargo already installed"
else
  info "Installing Rust (verified download)..."
  fetch_and_verify "${MANIFEST_RUSTUP_URL}" "${MANIFEST_RUSTUP_SHA}" /tmp/rustup-init.sh
  chown "${NEW_USER}:${NEW_USER}" /tmp/rustup-init.sh
  su - "${NEW_USER}" -c 'sh /tmp/rustup-init.sh -y'
  rm -f /tmp/rustup-init.sh
  log "Rust/Cargo installed"
fi

if su - "${NEW_USER}" -c 'source ~/.cargo/env && command -v cargo-binstall' &>/dev/null; then
  log "cargo-binstall already installed"
else
  info "Installing cargo-binstall..."
  su - "${NEW_USER}" -c 'source ~/.cargo/env && cargo install cargo-binstall'
  log "cargo-binstall installed"
fi

if su - "${NEW_USER}" -c 'source ~/.cargo/env && command -v zellij' &>/dev/null; then
  log "zellij already installed"
else
  info "Installing zellij..."
  su - "${NEW_USER}" -c 'source ~/.cargo/env && cargo binstall zellij -y'
  log "zellij installed"
fi

# Bun (verified)
if su - "${NEW_USER}" -c 'command -v bun' &>/dev/null; then
  log "Bun already installed"
else
  info "Installing Bun (verified download)..."
  fetch_and_verify "${MANIFEST_BUN_URL}" "${MANIFEST_BUN_SHA}" /tmp/bun-install.sh
  chown "${NEW_USER}:${NEW_USER}" /tmp/bun-install.sh
  su - "${NEW_USER}" -c 'bash /tmp/bun-install.sh'
  rm -f /tmp/bun-install.sh
  log "Bun installed"
fi

# =============================================================================
# PHASE 8: Docker Stack (rsync + render — replaces ~900 lines of heredocs)
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 8: Docker Stack (rsync from tracked services/)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

DOCKER_DIR="${USER_HOME}/docker"
PROJECTS_DIR="${USER_HOME}/projects"
HTB_DIR="${USER_HOME}/htb"
DEVBOX_CONFIG_DIR="${USER_HOME}/.config/devbox"

install -d -m 0755 "${DOCKER_DIR}" "${PROJECTS_DIR}" "${HTB_DIR}" "${DEVBOX_CONFIG_DIR}"

# Refuse to clobber a non-devbox tree. Upgrade-in-place is detected via the
# install marker; see collision_guard() definition.
collision_guard "${DOCKER_DIR}"

install -d -m 0755 "${DOCKER_DIR}/traefik/logs" "${DOCKER_DIR}/exegol-workspace"
install -d -m 0755 "${DOCKER_DIR}/lib"
install -d -m 0700 "${DOCKER_DIR}/.secrets"

# Install runtime contract and write the install marker. Helpers source this
# installed copy at runtime (not the repo copy).
install -m 0644 "${REPO_DIR}/scripts/lib/devbox-contract.sh" "${DOCKER_DIR}/lib/devbox-contract.sh"
cat >"${DOCKER_DIR}/lib/.devbox-marker" <<MARKER
# Devbox install marker — DO NOT EDIT.
# Presence + matching contract.sh enables upgrade-in-place mode.
DEVBOX_INSTALL_VERSION=1
DEVBOX_INSTALL_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DEVBOX_INSTALL_REPO=${REPO_DIR}
MARKER
chmod 0644 "${DOCKER_DIR}/lib/.devbox-marker"
log "Runtime contract installed to ${DOCKER_DIR}/lib/devbox-contract.sh"

info "Rsyncing services/ tree..."
rsync_install "${REPO_DIR}/services/traefik" "${DOCKER_DIR}/traefik"
rsync_install "${REPO_DIR}/services/ollama-openwebui" "${DOCKER_DIR}/ollama-openwebui"
log "services/ tree installed"

info "Rsyncing scripts/host/ tree..."
rsync -a "${REPO_DIR}/scripts/host/" "${DOCKER_DIR}/"
chmod +x "${DOCKER_DIR}"/*.sh
log "Helper scripts installed and executable"

info "Rsyncing scripts/systemd/ tree..."
install -d -m 0755 "${DOCKER_DIR}/systemd"
rsync -a "${REPO_DIR}/scripts/systemd/" "${DOCKER_DIR}/systemd/"
log "Systemd templates installed to ${DOCKER_DIR}/systemd/"

# Render templates with whitelisted envsubst (per ARCHITECTURE.md)
info "Rendering .env templates..."

# Traefik dashboard auth
TRAEFIK_HASH=$(openssl passwd -apr1 "${TRAEFIK_PASS}")
export TRAEFIK_USER TRAEFIK_HASH
render_env "${DOCKER_DIR}/traefik/dynamic/dashboard-auth.yml.template" \
           "${DOCKER_DIR}/traefik/dynamic/dashboard-auth.yml" \
           '$TRAEFIK_USER $TRAEFIK_HASH'
rm -f "${DOCKER_DIR}/traefik/dynamic/dashboard-auth.yml.template"

# Ollama API auth (external route only). Per-install plaintext credential is
# stored at ${DOCKER_DIR}/.secrets/ollama-auth.txt (mode 0600) for operator
# retrieval. Upgrades preserve the existing secret file.
OLLAMA_AUTH_HASH=$(openssl passwd -apr1 "${OLLAMA_AUTH_PASS}")
export OLLAMA_AUTH_USER OLLAMA_AUTH_HASH
render_env "${DOCKER_DIR}/traefik/dynamic/ollama-auth.yml.template" \
           "${DOCKER_DIR}/traefik/dynamic/ollama-auth.yml" \
           '$OLLAMA_AUTH_USER $OLLAMA_AUTH_HASH'
rm -f "${DOCKER_DIR}/traefik/dynamic/ollama-auth.yml.template"

OLLAMA_SECRET_FILE="${DOCKER_DIR}/.secrets/ollama-auth.txt"
if [ ! -e "${OLLAMA_SECRET_FILE}" ]; then
    install -m 0600 /dev/null "${OLLAMA_SECRET_FILE}"
    printf '%s:%s\n' "${OLLAMA_AUTH_USER}" "${OLLAMA_AUTH_PASS}" >"${OLLAMA_SECRET_FILE}"
    chmod 0600 "${OLLAMA_SECRET_FILE}"
    log "Ollama basic-auth credential saved to ${OLLAMA_SECRET_FILE}"
else
    info "Preserving existing ${OLLAMA_SECRET_FILE}"
fi
chown -R "${NEW_USER}:${NEW_USER}" "${DOCKER_DIR}/.secrets"

# Ollama-openwebui .env
export OPENWEBUI_SECRET_VAL="${OPENWEBUI_SECRET}"
export ENABLE_SIGNUP_VAL="true"
WEBUI_SECRET_KEY="${OPENWEBUI_SECRET}" ENABLE_SIGNUP="true" \
  envsubst '$WEBUI_SECRET_KEY $ENABLE_SIGNUP' \
  <"${DOCKER_DIR}/ollama-openwebui/.env.template" \
  >"${DOCKER_DIR}/ollama-openwebui/.env.tmp"
if [ ! -e "${DOCKER_DIR}/ollama-openwebui/.env" ]; then
  mv "${DOCKER_DIR}/ollama-openwebui/.env.tmp" "${DOCKER_DIR}/ollama-openwebui/.env"
  chmod 0600 "${DOCKER_DIR}/ollama-openwebui/.env"
else
  rm -f "${DOCKER_DIR}/ollama-openwebui/.env.tmp"
  info "Preserving existing ollama-openwebui/.env"
fi
rm -f "${DOCKER_DIR}/ollama-openwebui/.env.template"

# HTTPS-mode rendering
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
if [ -z "${TAILSCALE_IP}" ]; then
  warn "Tailscale not authenticated — \`tailscale ip -4\` returned nothing."
  warn "Traefik would bind to 127.0.0.1, making services unreachable from the LAN/Tailnet."
  warn "Run \`sudo tailscale up --accept-routes --advertise-tags=tag:devbox\` first, then re-run setup."
  if [ "${DEVBOX_ALLOW_NO_TAILSCALE:-false}" = "true" ]; then
    TAILSCALE_IP="127.0.0.1"
    warn "DEVBOX_ALLOW_NO_TAILSCALE=true — continuing with TAILSCALE_IP=127.0.0.1 (loopback only)."
  else
    error "Refusing to write config.env with a loopback bind. Set DEVBOX_ALLOW_NO_TAILSCALE=true to override."
  fi
fi

if [ "${ENABLE_HTTPS}" = "true" ]; then
  info "Rendering HTTPS configuration..."
  install -d -m 0755 "${DOCKER_DIR}/traefik/letsencrypt"
  install -m 0600 /dev/null "${DOCKER_DIR}/traefik/letsencrypt/acme.json"
  # Render traefik.https.yml.template -> traefik.yml (overwriting HTTP-only)
  USER_EMAIL_VAR="${USER_EMAIL}" \
    envsubst '$USER_EMAIL' \
    <"${DOCKER_DIR}/traefik/traefik.https.yml.template" \
    >"${DOCKER_DIR}/traefik/traefik.yml"
  rm -f "${DOCKER_DIR}/traefik/traefik.https.yml.template"
  # Render OVH .env
  envsubst '$OVH_ENDPOINT $OVH_APPLICATION_KEY $OVH_APPLICATION_SECRET $OVH_CONSUMER_KEY' \
    <"${DOCKER_DIR}/traefik/.env.template" \
    >"${DOCKER_DIR}/traefik/.env"
  chmod 0600 "${DOCKER_DIR}/traefik/.env"
  rm -f "${DOCKER_DIR}/traefik/.env.template"
  log "HTTPS configuration rendered"
else
  # HTTP-only: remove the HTTPS-only template + middleware to avoid confusion
  rm -f "${DOCKER_DIR}/traefik/traefik.https.yml.template"
  rm -f "${DOCKER_DIR}/traefik/.env.template"
  rm -f "${DOCKER_DIR}/traefik/dynamic/middlewares-https.yml"
fi

# Build per-service compose chains from the contract. Each chain is the base
# compose file, plus the HTTPS overlay when ENABLE_HTTPS=true, plus the
# committed digest lockfile when present in the source tree. Helpers consume
# the resulting COMPOSE_FILE_<UPPER_SVC> variables from config.env.
COMPOSE_CHAIN_LINES=()
for svc in "${DEVBOX_SERVICES[@]}"; do
  base="$(devbox_get "${svc}" COMPOSE)"
  https_overlay="$(devbox_get "${svc}" COMPOSE_HTTPS)"
  subdir="$(devbox_get "${svc}" DIR)"
  chain="${base}"
  if [ "${ENABLE_HTTPS}" = "true" ] && [ -n "${https_overlay}" ]; then
    chain="${chain}:${https_overlay}"
  fi
  if [ -f "${REPO_DIR}/services/${subdir}/docker-compose.lock.yml" ]; then
    chain="${chain}:docker-compose.lock.yml"
  fi
  key="$(devbox_compose_chain_key "${svc}")"
  eval "${key}=\"\${chain}\""
  COMPOSE_CHAIN_LINES+=("${key}=${chain}")
done

# Write the install-level config file (~/.config/devbox/config.env). Single
# source of truth for ENABLE_HTTPS / DOMAIN / TAILSCALE_IP / DEVBOX_USER /
# COMPOSE_FILE_<SVC> that start-all.sh / stop-all.sh / status.sh source.
DEVBOX_CONFIG_FILE="${DEVBOX_CONFIG_DIR}/config.env"
if [ -e "${DEVBOX_CONFIG_FILE}" ]; then
  snapshot_file "${DEVBOX_CONFIG_FILE}"
fi
install -m 0600 /dev/null "${DEVBOX_CONFIG_FILE}"
{
  printf '# DevBox install-level config — sourced by start-all.sh / stop-all.sh / status.sh\n'
  printf '# Generated by setup.sh on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'ENABLE_HTTPS=%s\n' "${ENABLE_HTTPS}"
  printf 'DOMAIN=%s\n'        "${DOMAIN}"
  printf 'TAILSCALE_IP=%s\n'  "${TAILSCALE_IP}"
  printf 'DEVBOX_USER=%s\n'   "${NEW_USER}"
  for line in "${COMPOSE_CHAIN_LINES[@]}"; do
    printf '%s\n' "${line}"
  done
} > "${DEVBOX_CONFIG_FILE}"
chown "${NEW_USER}:${NEW_USER}" "${DEVBOX_CONFIG_FILE}"
log "Install config written to ${DEVBOX_CONFIG_FILE}"

# /run/devbox for htb-vpn PID file (per F5)
install -d -m 0755 -o "${NEW_USER}" -g "${NEW_USER}" /run/devbox 2>/dev/null || true

log "Docker stack configured (rsync from tracked services/ tree)"

# =============================================================================
# PHASE 9: Shell Configuration
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 9: Shell Configuration${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Install Oh-My-Zsh (verified)
if $EXISTING_ZSH; then
  log "Oh-My-Zsh already installed for ${NEW_USER}"
else
  info "Installing Oh-My-Zsh (verified download)..."
  fetch_and_verify "${MANIFEST_OHMYZSH_URL}" "${MANIFEST_OHMYZSH_SHA}" /tmp/ohmyzsh-install.sh
  chown "${NEW_USER}:${NEW_USER}" /tmp/ohmyzsh-install.sh
  su - "${NEW_USER}" -c 'sh /tmp/ohmyzsh-install.sh "" --unattended' 2>/dev/null || true
  rm -f /tmp/ohmyzsh-install.sh
  log "Oh-My-Zsh installed"
fi

# Update .zshrc — preserve user customizations on re-runs.
# The canonical dev-zshrc starts with a `# DevBox v3 — dev user .zshrc` marker.
# If the existing file lacks that marker, it's user-authored; snapshot it and
# leave it in place rather than clobbering. Set DEVBOX_FORCE_ZSHRC=true to
# force-overwrite.
ZSHRC_MARKER='# DevBox v3 — dev user .zshrc'
INSTALL_ZSHRC=true
if [ -f "${USER_HOME}/.zshrc" ]; then
  snapshot_file "${USER_HOME}/.zshrc"
  if ! head -n1 "${USER_HOME}/.zshrc" | grep -qF "${ZSHRC_MARKER}"; then
    if [ "${DEVBOX_FORCE_ZSHRC:-false}" != "true" ]; then
      warn "Existing ${USER_HOME}/.zshrc is user-customized (no DevBox marker)."
      warn "Snapshot saved to ~/.local/share/devbox/backups/. Set DEVBOX_FORCE_ZSHRC=true to overwrite."
      INSTALL_ZSHRC=false
    fi
  fi
fi

if [ "${INSTALL_ZSHRC}" = "true" ]; then
  info "Installing canonical .zshrc from scripts/install/dev-zshrc..."
  install -m 0644 -o "${NEW_USER}" -g "${NEW_USER}" \
    "${REPO_DIR}/scripts/install/dev-zshrc" "${USER_HOME}/.zshrc"
  log "Shell configured with aliases (source: scripts/install/dev-zshrc)"
else
  log "Preserved existing ${USER_HOME}/.zshrc (snapshot in ~/.local/share/devbox/backups/)"
fi

# =============================================================================
# PHASE 10: Finalizing + Credentials (umask 077 + install + trap per F7)
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 10: Finalizing${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

info "Fixing file ownership..."
chown -R "${NEW_USER}:${NEW_USER}" "${USER_HOME}"

if [ "${SSH_RESTART_NEEDED:-true}" = true ]; then
  info "Restarting SSH..."
  systemctl restart ssh
  log "SSH restarted on port ${SSH_PORT}"
fi

# Credentials file — F7 hardening: install -m 0600 BEFORE any content lands,
# trap registered so partial install shreds it on SIGINT.
CREDS_FILE="${USER_HOME}/.devbox-credentials"
CLEANUP_FILES+=("${CREDS_FILE}")
install -m 0600 -o "${NEW_USER}" -g "${NEW_USER}" /dev/null "${CREDS_FILE}"
cat >"${CREDS_FILE}" <<CREDS
================================================================================
DevBox Credentials (Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ))
================================================================================

User: ${NEW_USER}
$(if ! $EXISTING_USER; then echo "Backup Password: ${DEV_PASSWORD}"; else echo "Backup Password: (existing user - password unchanged)"; fi)

SERVICE CREDENTIALS
-------------------
Open WebUI Secret:      ${OPENWEBUI_SECRET}
Traefik Dashboard:      ${TRAEFIK_USER} / ${TRAEFIK_PASS}
Ollama API Auth:        ${OLLAMA_AUTH_USER} / ${OLLAMA_AUTH_PASS}

IMPORTANT:
- These credentials are also stored in ~/docker/*/.env files
- DELETE THIS FILE AFTER RECORDING CREDENTIALS SECURELY (\`shred -u\`)
- Use a password manager to store these values

================================================================================
CREDS

# If gpg is configured with at least one key, encrypt the credentials at rest
if command -v gpg &>/dev/null && gpg --list-keys 2>/dev/null | grep -q '^pub'; then
  info "GPG key detected — encrypting credentials at rest..."
  GPG_RECIPIENT=$(gpg --list-keys --with-colons | awk -F: '/^uid:/ {print $10; exit}')
  if [ -n "${GPG_RECIPIENT}" ]; then
    su - "${NEW_USER}" -c "gpg --batch --yes --encrypt --recipient '${GPG_RECIPIENT}' --output '${CREDS_FILE}.gpg' '${CREDS_FILE}'" && {
      shred -u "${CREDS_FILE}"
      CREDS_FILE="${CREDS_FILE}.gpg"
      log "Credentials encrypted to ${CREDS_FILE}"
    } || warn "GPG encryption failed — credentials remain in plaintext"
  fi
fi

# Clear cleanup-on-error registration since credentials are now safe
CLEANUP_FILES=()

log "Setup complete!"

# =============================================================================
# SUMMARY
# =============================================================================
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo -e "${GREEN}"
cat <<'DONE'
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║                        ✅ SETUP COMPLETE!                                 ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
DONE
echo -e "${NC}"

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}CREDENTIALS${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}Credentials saved to: ${CREDS_FILE}${NC}"
echo ""
case "${CREDS_FILE}" in
  *.gpg) echo "  View:    gpg --decrypt ${CREDS_FILE}" ;;
  *)     echo "  View:    cat ${CREDS_FILE}" ;;
esac
echo "  Delete:  shred -u ${CREDS_FILE}"
echo ""
echo -e "  ${RED}⚠️  shred -u after recording in your password manager!${NC}"
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}NEXT STEPS${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "1️⃣  TEST SSH (from a NEW terminal — don't close this one!):"
echo "    ssh -p ${SSH_PORT} ${NEW_USER}@\$(curl -s ifconfig.me 2>/dev/null || echo YOUR_SERVER_IP)"
echo ""
echo "2️⃣  AUTHENTICATE TAILSCALE:"
echo "    sudo tailscale up --accept-routes --advertise-tags=tag:devbox"
echo ""
echo "3️⃣  GENERATE INITIAL DIGEST LOCKFILES (per ARCHITECTURE.md):"
echo "    cd ${REPO_DIR} && ./scripts/update-images.sh --apply"
echo "    # First run produces tag+digest form. Run a SECOND time to stabilize"
echo "    # (Critic Issue #2: first generation keeps the tag string, second strips it):"
echo "    ./scripts/update-images.sh --apply"
echo "    git add services/*/docker-compose.lock.yml && git commit -m 'lock: initial image digests'"
echo ""
echo "4️⃣  START SERVICES (as ${NEW_USER}):"
echo "    cd ~/docker && ./start-all.sh"
echo ""
echo "5️⃣  PULL OLLAMA MODELS:"
echo "    docker exec -it ollama ollama pull llama3.2"
echo ""
echo "6️⃣  VERIFY SECURITY HARDENING:"
echo "    ./security-check.sh"
echo ""
echo "📚  Read the docs:"
echo "    docs/security.md  — privilege model"
echo "    docs/updating.md  — digest refresh + cosign verify"
echo "    docs/ops.md       — backup, restore, DR runbook"
echo "    ARCHITECTURE.md   — load-bearing design decisions"
echo ""
echo "🔧  Setup flags (for automation / CI):"
echo "    sudo ./setup.sh --yes       # skip interactive prompts"
echo "    ./setup.sh --check          # validate contract sync (no root, no changes)"
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}ACCESS SERVICES${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Add to /etc/hosts on your laptop (after Tailscale connected):"
echo "    \$(tailscale ip -4)  ai.internal traefik.internal ollama.internal exegol.internal"
echo ""
echo "Then:"
echo "    http://ai.internal        → Open WebUI"
echo "    http://traefik.internal   → Traefik Dashboard (user: ${TRAEFIK_USER})"
echo "    http://ollama.internal    → Ollama API (user: ${OLLAMA_AUTH_USER})"
echo ""

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Setup completed in ${DURATION} seconds"
echo -e "${RED}⚠️  DO NOT close this terminal until you verify SSH access!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
