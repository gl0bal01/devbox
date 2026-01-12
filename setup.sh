#!/usr/bin/env bash
# =============================================================================
# DEVBOX FULL SETUP SCRIPT v2.3 (Security Hardened)
# =============================================================================
# Remote Dev/Pentest/AI Station - Production Ready
#
# Target: Ubuntu 24.04 with Docker pre-installed (Hostinger Docker image)
# Stack:  Tailscale + Traefik (internal) + Ollama + Ai Dev Stack (Claude Code, OpenCode, Goose, LLM, Fabric) + Exegol
#
# Security Hardening Applied:
#   - Secrets stored in .env files with 600 permissions (not in compose files)
#   - Docker socket proxy for Traefik (prevents container escape via socket)
#   - Traefik dashboard protected with basicAuth
#   - All containers have: no-new-privileges, cap_drop ALL, resource limits
#   - Using :latest tags for all services (always up-to-date)
#   - Health checks on all services
#   - Exegol runs with specific capabilities (not --privileged by default)
#   - Global .gitignore to prevent accidental secret commits
#
# Features:
#   - User creation with SSH key auth
#   - SSH hardening (custom port, key-only)
#   - UFW firewall
#   - Tailscale VPN (zero public exposure)
#   - Traefik reverse proxy (internal routing)
#   - Ollama + Open WebUI (local AI)
#   - Exegol (pentest container)
#   - Ai Dev Stack (Claude Code, OpenCode, Goose, LLM, Fabric)
#   - mise (polyglot version manager)
#
# Usage:
#   1. Edit CONFIGURATION section below
#   2. Run as root: ./setup.sh
#   3. Follow post-install instructions
#   4. Run ~/docker/security-check.sh to verify hardening
#
# Author: gl0bal01
# Date: January 2026
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION - EDIT THESE VALUES
# =============================================================================

# User settings
NEW_USER="dev"
USER_EMAIL="admin@example.com" # Used for Let's Encrypt (future)

# SSH settings
SSH_PORT="5522" # Non-standard port (security)

# SECURITY: SSH public key - read from environment variable or file
# Priority: 1) SSH_PUBLIC_KEY env var, 2) ~/.ssh/authorized_key file, 3) empty (add manually)
if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
  : # Use environment variable if set
elif [ -f "${HOME}/.ssh/devbox_authorized_key" ]; then
  SSH_PUBLIC_KEY=$(cat "${HOME}/.ssh/devbox_authorized_key" 2>/dev/null | head -1)
elif [ -f "/root/.ssh/devbox_authorized_key" ]; then
  SSH_PUBLIC_KEY=$(cat "/root/.ssh/devbox_authorized_key" 2>/dev/null | head -1)
else
  SSH_PUBLIC_KEY="" # Will prompt user to add manually
fi

# Passwords for services (auto-generated if empty)
OPENWEBUI_SECRET="" # Leave empty to auto-generate

# Domain (for future Cloudflare Tunnel / public access)
DOMAIN="example.com"

# =============================================================================
# DO NOT EDIT BELOW THIS LINE (unless you know what you're doing)
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging functions
log() { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() {
  echo -e "${RED}[✗]${NC} $1"
  exit 1
}

# Password generator
generate_password() {
  openssl rand -base64 18 | tr -d '/+='
}

# Generate passwords if not set
[ -z "$OPENWEBUI_SECRET" ] && OPENWEBUI_SECRET=$(generate_password)
DEV_PASSWORD=$(generate_password)

# SECURITY: Traefik dashboard credentials (generated here for summary display)
TRAEFIK_USER="admin"
TRAEFIK_PASS=$(generate_password)

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

# Must be root
[ "$(id -u)" -ne 0 ] && error "This script must be run as root"

# Check OS
if ! grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
  warn "This script is designed for Ubuntu. Proceed with caution."
fi

# =============================================================================
# DETECT EXISTING INSTALLATIONS
# =============================================================================

EXISTING_USER=false
EXISTING_DOCKER=false
EXISTING_TAILSCALE=false
EXISTING_MISE=false
EXISTING_ZSH=false
EXISTING_EXEGOL=false

# Check user
id "${NEW_USER}" &>/dev/null && EXISTING_USER=true

# Check Docker
command -v docker &>/dev/null && EXISTING_DOCKER=true

# Check Tailscale
command -v tailscale &>/dev/null && EXISTING_TAILSCALE=true

# Check mise
([ -x "/opt/mise" ] || [ -x "/usr/local/bin/mise" ] || command -v mise &>/dev/null) && EXISTING_MISE=true

# Check Oh-My-Zsh for user
[ -d "/home/${NEW_USER}/.oh-my-zsh" ] && EXISTING_ZSH=true

# Check if Exegol image exists
docker images 2>/dev/null | grep -q "Exegol-images\|exegol" && EXISTING_EXEGOL=true

# Banner
echo -e "${CYAN}"
cat <<'EOF'
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║     ██████╗ ███████╗██╗   ██╗██████╗  ██████╗ ██╗  ██╗                    ║
║     ██╔══██╗██╔════╝██║   ██║██╔══██╗██╔═══██╗╚██╗██╔╝                    ║
║     ██║  ██║█████╗  ██║   ██║██████╔╝██║   ██║ ╚███╔╝                     ║
║     ██║  ██║██╔══╝  ╚██╗ ██╔╝██╔══██╗██║   ██║ ██╔██╗                     ║
║     ██████╔╝███████╗ ╚████╔╝ ██████╔╝╚██████╔╝██╔╝ ██╗                    ║
║     ╚═════╝ ╚══════╝  ╚═══╝  ╚═════╝  ╚═════╝ ╚═╝  ╚═╝                    ║
║                                                                           ║
║     Remote Dev / Pentest / AI Station Setup                               ║
║     Tailscale + Traefik + Ollama + Ai Dev Stack + Exegol                  ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

echo -e "${YELLOW}Configuration:${NC}"
echo "  User:        ${NEW_USER}"
echo "  SSH Port:    ${SSH_PORT}"
echo "  Domain:      ${DOMAIN}"
echo "  SSH Key:     ${SSH_PUBLIC_KEY:+Provided}${SSH_PUBLIC_KEY:-Not provided (add manually)}"
echo ""

echo -e "${YELLOW}Detected Existing Installations:${NC}"
$EXISTING_USER && echo "  ✓ User '${NEW_USER}' exists" || echo "  ○ User '${NEW_USER}' will be created"
$EXISTING_DOCKER && echo "  ✓ Docker installed" || echo "  ✗ Docker NOT found (required!)"
$EXISTING_TAILSCALE && echo "  ✓ Tailscale installed" || echo "  ○ Tailscale will be installed"
$EXISTING_MISE && echo "  ✓ mise installed" || echo "  ○ mise will be installed"
$EXISTING_ZSH && echo "  ✓ Oh-My-Zsh configured" || echo "  ○ Oh-My-Zsh will be installed"
$EXISTING_EXEGOL && echo "  ✓ Exegol image found" || echo "  ○ Exegol will be pulled on first use"
echo ""

# Docker is required
if ! $EXISTING_DOCKER; then
  error "Docker not found! This script requires Docker pre-installed (Hostinger Docker image)."
fi

read -p "Continue with setup? (y/N) " -n 1 -r
echo
[[ ! $REPLY =~ ^[Yy]$ ]] && exit 0

START_TIME=$(date +%s)

# =============================================================================
# PHASE 1: System Update & Essential Packages
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 1: System Update & Essential Packages${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Fix locale first to avoid perl warnings
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
  ufw fail2ban \
  build-essential \
  openvpn wireguard-tools \
  python3-pip python3-venv \
  net-tools dnsutils iputils-ping

log "System packages installed"

# =============================================================================
# PHASE 2: Create User
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 2: Create User '${NEW_USER}'${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if $EXISTING_USER; then
  log "User '${NEW_USER}' already exists"
  USER_HOME=$(getent passwd "${NEW_USER}" | cut -d: -f6)

  # Still ensure user is in sudo and docker groups
  usermod -aG sudo "${NEW_USER}" 2>/dev/null || true

  # Check for existing sudo config
  if [ ! -f "/etc/sudoers.d/90-${NEW_USER}" ]; then
    echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/90-${NEW_USER}"
    chmod 0440 "/etc/sudoers.d/90-${NEW_USER}"
    log "Passwordless sudo configured"
  else
    log "Passwordless sudo already configured"
  fi
else
  info "Creating user '${NEW_USER}'..."
  useradd -m -s /bin/zsh "${NEW_USER}"
  echo "${NEW_USER}:${DEV_PASSWORD}" | chpasswd
  USER_HOME="/home/${NEW_USER}"

  # Sudo without password
  usermod -aG sudo "${NEW_USER}"
  echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/90-${NEW_USER}"
  chmod 0440 "/etc/sudoers.d/90-${NEW_USER}"
  log "User '${NEW_USER}' created with passwordless sudo"
fi

# SSH directory (safe to run multiple times)
info "Setting up SSH directory..."
mkdir -p "${USER_HOME}/.ssh"
touch "${USER_HOME}/.ssh/authorized_keys"
chmod 700 "${USER_HOME}/.ssh"
chmod 600 "${USER_HOME}/.ssh/authorized_keys"
chown -R "${NEW_USER}:${NEW_USER}" "${USER_HOME}/.ssh"

# Add SSH key if provided and not already present
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

# Check if already hardened
EXISTING_SSH_HARDENING=false
[ -f "/etc/ssh/sshd_config.d/99-hardening.conf" ] && EXISTING_SSH_HARDENING=true

if $EXISTING_SSH_HARDENING; then
  CURRENT_PORT=$(grep "^Port" /etc/ssh/sshd_config.d/99-hardening.conf 2>/dev/null | awk '{print $2}')
  log "SSH hardening already configured (port ${CURRENT_PORT:-unknown})"

  if [ "${CURRENT_PORT}" != "${SSH_PORT}" ]; then
    warn "Current SSH port (${CURRENT_PORT}) differs from config (${SSH_PORT})"
    read -p "Update SSH port to ${SSH_PORT}? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      EXISTING_SSH_HARDENING=false
    fi
  fi
fi

if ! $EXISTING_SSH_HARDENING; then
  info "Backing up SSH config..."
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d%H%M%S) 2>/dev/null || true

  info "Applying SSH hardening..."
  mkdir -p /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/99-hardening.conf <<EOF
# DevBox SSH Hardening
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
# SECURITY: Using KbdInteractiveAuthentication instead of deprecated ChallengeResponseAuthentication
KbdInteractiveAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

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

# SECURITY: Check for existing UFW rules before reset
EXISTING_UFW_RULES=$(ufw status 2>/dev/null | grep -c "ALLOW\|DENY" || echo "0")
if [ "$EXISTING_UFW_RULES" -gt "0" ]; then
  warn "Existing UFW rules detected (${EXISTING_UFW_RULES} rules)"
  read -p "Reset UFW and apply DevBox firewall rules? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Keeping existing UFW rules - ensure SSH port ${SSH_PORT} is allowed!"
    ufw allow ${SSH_PORT}/tcp comment "SSH" 2>/dev/null || true
  else
    info "Configuring UFW firewall..."
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ${SSH_PORT}/tcp comment "SSH"
    ufw --force enable
    log "Firewall configured (only SSH:${SSH_PORT} open)"
  fi
else
  info "Configuring UFW firewall..."
  ufw --force reset >/dev/null 2>&1
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow ${SSH_PORT}/tcp comment "SSH"
  ufw --force enable
  log "Firewall configured (only SSH:${SSH_PORT} open)"
fi

# =============================================================================
# PHASE 5: Docker Verification
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 5: Docker Verification${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Already verified in pre-flight, just show versions
DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | tr -d ',')
log "Docker: v${DOCKER_VERSION}"

if docker compose version &>/dev/null; then
  COMPOSE_VERSION=$(docker compose version --short)
  log "Docker Compose: v${COMPOSE_VERSION}"
else
  warn "Docker Compose plugin not found - trying to install..."
  apt install -y -qq docker-compose-plugin
fi

# Add user to docker group (safe to run multiple times)
usermod -aG docker "${NEW_USER}"
log "User '${NEW_USER}' added to docker group"

# Create networks (ignore if exists)
docker network create proxy-net 2>/dev/null && log "Docker network 'proxy-net' created" || log "Docker network 'proxy-net' already exists"

# =============================================================================
# PHASE 6: Tailscale
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 6: Tailscale VPN${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if $EXISTING_TAILSCALE; then
  TS_VERSION=$(tailscale version | head -1)
  log "Tailscale already installed: ${TS_VERSION}"

  # Check if connected
  if tailscale status &>/dev/null; then
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
    log "Tailscale connected (IP: ${TS_IP})"
  else
    info "Tailscale installed but not authenticated"
  fi
else
  info "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
  log "Tailscale installed (authenticate after script completes)"
fi

# =============================================================================
# PHASE 7: mise (Version Manager)
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 7: mise (Polyglot Version Manager)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Fix locale issues first
info "Configuring locale..."
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 >/dev/null 2>&1 || true

if $EXISTING_MISE; then
  MISE_VERSION=$(mise --version 2>/dev/null || echo "unknown")
  log "mise already installed: ${MISE_VERSION}"
else
  info "Installing mise..."
  export MISE_INSTALL_PATH=/opt/mise
  curl -fsSL https://mise.run | sh
  # Create symlink so mise is in standard PATH
  ln -sf /opt/mise /usr/local/bin/mise
  log "mise installed"
fi

# Ensure symlink exists (in case of re-run)
[ -f /opt/mise ] && [ ! -L /usr/local/bin/mise ] && ln -sf /opt/mise /usr/local/bin/mise

# Shell integration for all users
mkdir -p /etc/profile.d

cat >/etc/profile.d/mise.sh <<'EOF'
if [ -z "$SUDO_USER" ] && command -v mise &>/dev/null; then
    eval "$(mise activate bash)"
fi
EOF

# Activate for dev user's zsh
if [ -d "${USER_HOME}" ]; then
  mkdir -p "${USER_HOME}/.config/mise"

  # Add to .zshrc if not already present
  if ! grep -q "mise activate" "${USER_HOME}/.zshrc" 2>/dev/null; then
    cat >>"${USER_HOME}/.zshrc" <<'EOF'

# mise (version manager)
export PATH="/opt/mise:$PATH"
eval "$(/opt/mise activate zsh)"
EOF
  fi

  # Install default tools for dev user
  info "Installing default tools via mise for ${NEW_USER}..."
  su - "${NEW_USER}" -c 'export PATH="/opt/mise:$PATH" && mise use --global node@22' 2>/dev/null || true
fi

log "mise shell integration configured"

# =============================================================================
# PHASE 7b: Lazy Tools (lazygit, lazydocker, lazyvim)
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 7b: Lazy Tools (lazygit, lazydocker, lazyvim)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# lazygit
if command -v lazygit &>/dev/null; then
  log "lazygit already installed"
else
  info "Installing lazygit..."
  LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
  curl -Lo /tmp/lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
  tar xf /tmp/lazygit.tar.gz -C /tmp lazygit
  install /tmp/lazygit /usr/local/bin
  rm -f /tmp/lazygit /tmp/lazygit.tar.gz
  log "lazygit installed"
fi

# lazydocker
if command -v lazydocker &>/dev/null; then
  log "lazydocker already installed"
else
  info "Installing lazydocker..."
  curl -fsSL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash
  log "lazydocker installed"
fi

# neovim (required for lazyvim)
if command -v nvim &>/dev/null; then
  log "neovim already installed"
else
  info "Installing neovim..."
  curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
  tar -C /opt -xzf nvim-linux-x86_64.tar.gz
  ln -sf /opt/nvim-linux64/bin/nvim /usr/local/bin/nvim
  rm -f nvim-linux-x86_64.tar.gz
  export PATH="$PATH:/opt/nvim-linux-x86_64/bin"
  log "neovim installed"
fi

# lazyvim config for dev user
if [ -d "${USER_HOME}/.config/nvim" ]; then
  log "nvim config already exists (skipping lazyvim)"
else
  info "Installing lazyvim for ${NEW_USER}..."
  su - "${NEW_USER}" -c '
        # Backup existing configs
        mv ~/.config/nvim{,.bak} 2>/dev/null || true
        mv ~/.local/share/nvim{,.bak} 2>/dev/null || true
        mv ~/.local/state/nvim{,.bak} 2>/dev/null || true
        mv ~/.cache/nvim{,.bak} 2>/dev/null || true

        # Clone lazyvim starter
        git clone https://github.com/LazyVim/starter ~/.config/nvim
        rm -rf ~/.config/nvim/.git
    ' 2>/dev/null || true
  log "lazyvim installed for ${NEW_USER}"
fi

# =============================================================================
# PHASE 8: Docker Stack
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 8: Docker Stack Configuration${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

DOCKER_DIR="${USER_HOME}/docker"
PROJECTS_DIR="${USER_HOME}/projects"
HTB_DIR="${USER_HOME}/htb"

# Check if docker stack already exists
EXISTING_STACK=false
[ -f "${DOCKER_DIR}/traefik/docker-compose.yml" ] && EXISTING_STACK=true

if $EXISTING_STACK; then
  warn "Docker stack already exists at ${DOCKER_DIR}"
  read -p "Overwrite existing configuration? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Skipping docker stack configuration (keeping existing)"
    # Still create directories and scripts if missing
    mkdir -p "${DOCKER_DIR}"/{traefik/{dynamic,logs},ollama-openwebui,exegol-workspace}
    mkdir -p "${PROJECTS_DIR}"
    mkdir -p "${HTB_DIR}"
  else
    EXISTING_STACK=false
  fi
fi

if ! $EXISTING_STACK; then
  info "Creating directory structure..."
  mkdir -p "${DOCKER_DIR}"/{traefik/{dynamic,logs},ollama-openwebui,exegol-workspace}
  mkdir -p "${PROJECTS_DIR}"
  mkdir -p "${HTB_DIR}"

  # SECURITY: Global .gitignore to prevent accidental secret commits
  cat >"${DOCKER_DIR}/.gitignore" <<'EOF'
# SECURITY: Never commit secrets
**/.env
**/secrets/
*.key
*.pem
*.crt

# Docker data directories (may contain sensitive info)
**/data/
**/*-data/

# Logs
*.log
EOF

  log "Created global .gitignore for docker directory"

  # ---------------------------------------------------------------------------
  # Traefik (Internal Reverse Proxy) - SECURITY HARDENED
  # ---------------------------------------------------------------------------
  info "Creating Traefik configuration..."

  # Generate password hash for Traefik basicAuth (uses pre-generated TRAEFIK_PASS)
  TRAEFIK_HASH=$(openssl passwd -apr1 "${TRAEFIK_PASS}")

  cat >"${DOCKER_DIR}/traefik/docker-compose.yml" <<'EOF'
services:
  # SECURITY: Docker socket proxy limits API access (Critical Fix #2)
  # Only expose read-only endpoints needed by Traefik
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: docker-socket-proxy
    restart: unless-stopped
    environment:
      # Read-only access
      CONTAINERS: 1
      NETWORKS: 1
      SERVICES: 1
      TASKS: 1
      # Explicitly deny write operations
      POST: 0
      BUILD: 0
      COMMIT: 0
      CONFIGS: 0
      DISTRIBUTION: 0
      EXEC: 0
      IMAGES: 0
      # SECURITY: INFO disabled to prevent Docker daemon info exposure (HIGH-1 fix)
      INFO: 0
      NODES: 0
      PLUGINS: 0
      SECRETS: 0
      SWARM: 0
      SYSTEM: 0
      VOLUMES: 0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - socket-proxy
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /run
      - /tmp
    mem_limit: 64m
    cpus: 0.25
    pids_limit: 50

  traefik:
    image: traefik:latest
    container_name: traefik
    restart: unless-stopped
    depends_on:
      - docker-socket-proxy
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    tmpfs:
      - /tmp
    ports:
      - "80:80"      # Safe: UFW blocks public, only Tailscale can reach
    volumes:
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./dynamic:/etc/traefik/dynamic:ro
      - ./logs:/var/log/traefik
    networks:
      - proxy-net
      - socket-proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(`traefik.internal`)"
      - "traefik.http.routers.traefik.entrypoints=web"
      - "traefik.http.routers.traefik.service=api@internal"
      # SECURITY: Dashboard authentication
      - "traefik.http.routers.traefik.middlewares=dashboard-auth@file"
    healthcheck:
      test: ["CMD", "traefik", "healthcheck"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    # Resource limits (High Fix #7)
    mem_limit: 256m
    memswap_limit: 256m
    cpus: 0.5
    pids_limit: 100

networks:
  proxy-net:
    external: true
  socket-proxy:
    driver: bridge
    internal: true
EOF

  cat >"${DOCKER_DIR}/traefik/traefik.yml" <<'EOF'
global:
  checkNewVersion: true
  sendAnonymousUsage: false

entryPoints:
  web:
    address: ":80"

providers:
  # SECURITY: Use socket proxy instead of direct socket access
  docker:
    endpoint: "tcp://docker-socket-proxy:2375"
    exposedByDefault: false
    network: proxy-net
  file:
    directory: /etc/traefik/dynamic
    watch: true

api:
  dashboard: true
  # SECURITY: Dashboard protected by basicAuth middleware, insecure disabled
  insecure: false

# Enable ping endpoint for health checks
ping: {}

# SECURITY: Log rotation to prevent disk exhaustion
log:
  level: INFO
  filePath: /var/log/traefik/traefik.log
  maxSize: 10
  maxBackups: 3
  maxAge: 7

accessLog:
  filePath: /var/log/traefik/access.log
  bufferingSize: 100
EOF

  # Dynamic config with authentication middleware
  cat >"${DOCKER_DIR}/traefik/dynamic/dashboard-auth.yml" <<EOF
http:
  middlewares:
    dashboard-auth:
      basicAuth:
        users:
          - "${TRAEFIK_USER}:${TRAEFIK_HASH}"
        removeHeader: true
EOF

  # SECURITY: Restrict permissions on password hash file
  chmod 600 "${DOCKER_DIR}/traefik/dynamic/dashboard-auth.yml"

  log "Traefik configured with socket proxy and dashboard auth"

  # ---------------------------------------------------------------------------
  # Ollama + Open WebUI - SECURITY HARDENED
  # ---------------------------------------------------------------------------
  info "Creating Ollama + Open WebUI configuration..."

  # SECURITY: Create .env file with proper permissions
  cat >"${DOCKER_DIR}/ollama-openwebui/.env" <<EOF
# SECURITY: Secrets stored in .env file with restricted permissions
# DO NOT commit this file to version control
WEBUI_SECRET_KEY=${OPENWEBUI_SECRET}
# Set to false after creating admin account
ENABLE_SIGNUP=true
EOF
  chmod 600 "${DOCKER_DIR}/ollama-openwebui/.env"

  # Add .env to .gitignore
  echo ".env" >"${DOCKER_DIR}/ollama-openwebui/.gitignore"

  cat >"${DOCKER_DIR}/ollama-openwebui/docker-compose.yml" <<'EOF'
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    # SECURITY: Security hardening
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - DAC_OVERRIDE
      - FOWNER
      - SYS_RESOURCE    # May be needed for GPU memory management
    volumes:
      - ./ollama-data:/root/.ollama
    ports:
      - "127.0.0.1:11434:11434"    # Localhost only for Claude Code
    networks:
      - proxy-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.ollama-api.rule=Host(`ollama.internal`)"
      - "traefik.http.services.ollama-api.loadbalancer.server.port=11434"
    # SECURITY: Resource limits
    # Adjust mem_limit based on your models (llama3.2 needs ~4GB, larger models need more)
    mem_limit: 24g
    memswap_limit: 24g
    cpus: 4
    pids_limit: 200
    healthcheck:
      test: ["CMD", "ollama", "list"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    # Uncomment if you have NVIDIA GPU + nvidia-container-toolkit:
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - driver: nvidia
    #           count: all
    #           capabilities: [gpu]

  openwebui:
    image: ghcr.io/open-webui/open-webui:latest
    container_name: open-webui
    restart: unless-stopped
    depends_on:
      ollama:
        condition: service_healthy
    # SECURITY: Security hardening
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - DAC_OVERRIDE
      - FOWNER
    # Note: Open WebUI needs write access to /app/backend/data, so read_only: true
    # would require extensive tmpfs mounts. Using volume isolation instead.
    environment:
      - OLLAMA_BASE_URLS=http://ollama:11434
      # SECURITY: Secrets loaded from .env file
      - WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}
      # SECURITY: Disable signup after creating admin
      - ENABLE_SIGNUP=${ENABLE_SIGNUP:-false}
    volumes:
      - ./openwebui-data:/app/backend/data
    networks:
      - proxy-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.openwebui.rule=Host(`ai.internal`)"
      - "traefik.http.services.openwebui.loadbalancer.server.port=8080"
    # SECURITY: Resource limits
    mem_limit: 2g
    memswap_limit: 2g
    cpus: 1
    pids_limit: 200
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

networks:
  proxy-net:
    external: true
EOF

  log "Ollama + Open WebUI configured with security hardening"

  # ---------------------------------------------------------------------------
  # Helper Scripts
  # ---------------------------------------------------------------------------
  info "Creating helper scripts..."

  # start-all.sh
  cat >"${DOCKER_DIR}/start-all.sh" <<'EOF'
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

echo "🚀 Starting all services..."
echo ""

echo "  → Traefik (with docker-socket-proxy)..."
cd traefik && docker compose up -d && cd ..

# Wait for socket proxy to be ready
echo "  → Waiting for docker-socket-proxy..."
sleep 3

echo "  → Ollama + Open WebUI..."
cd ollama-openwebui && docker compose up -d && cd ..

echo ""
echo "✅ All services started!"
echo ""
echo "📊 Service Status:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "🔒 Security: All containers running with hardened configurations"
echo "   • Secrets stored in .env files (not in compose files)"
echo "   • Traefik using docker-socket-proxy"
echo "   • Resource limits applied"
EOF

  # stop-all.sh
  cat >"${DOCKER_DIR}/stop-all.sh" <<'EOF'
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

echo "🛑 Stopping all services..."

for dir in ollama-openwebui traefik; do
    if [ -d "$dir" ]; then
        echo "  → Stopping ${dir}..."
        cd "$dir" && docker compose down && cd ..
    fi
done

echo ""
echo "✅ All services stopped."
EOF

  # status.sh
  cat >"${DOCKER_DIR}/status.sh" <<'EOF'
#!/usr/bin/env bash
echo "📊 Docker Services Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""

echo "🔒 Security Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
# Check if docker-socket-proxy is running
if docker ps --format '{{.Names}}' | grep -q docker-socket-proxy; then
    echo "  ✅ Docker socket proxy: running"
else
    echo "  ⚠️  Docker socket proxy: not running"
fi

# Check for containers running as root
ROOT_CONTAINERS=$(docker ps -q | xargs -r docker inspect --format '{{.Name}} {{.Config.User}}' 2>/dev/null | grep -E "^/[^ ]+ (0|root|)$" | cut -d'/' -f2 | cut -d' ' -f1)
if [ -n "$ROOT_CONTAINERS" ]; then
    echo "  ⚠️  Containers running as root: $ROOT_CONTAINERS"
else
    echo "  ✅ No containers running as root (or expected ones only)"
fi
echo ""

echo "📡 Tailscale Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
tailscale status 2>/dev/null || echo "  Tailscale not connected"
echo ""

echo "🌐 Access URLs (add to /etc/hosts on your laptop):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TSIP=$(tailscale ip -4 2>/dev/null || echo "TAILSCALE_IP")
echo "  ${TSIP}  ai.internal traefik.internal ollama.internal"
echo ""
echo "  http://ai.internal        → Open WebUI"
echo "  http://traefik.internal   → Traefik Dashboard (requires auth)"
echo "  http://ollama.internal    → Ollama API"
EOF

  # exegol-htb.sh
  cat >"${DOCKER_DIR}/exegol-htb.sh" <<'EOF'
#!/usr/bin/env bash
# Start Exegol for HTB/pentest with host network (inherits VPN)
# Usage: ./exegol-htb.sh [container-name] [--privileged]
#
# SECURITY NOTE: This script uses specific capabilities instead of --privileged
# by default. Use --privileged flag only if you encounter issues with specific
# tools that require full privileges (rare).

NAME="${1:-exegol-htb}"
WORKSPACE="${HOME}/docker/exegol-workspace"
USE_PRIVILEGED=false

# Check for --privileged flag
for arg in "$@"; do
    if [[ "$arg" == "--privileged" ]]; then
        USE_PRIVILEGED=true
        echo "⚠️  WARNING: Running with --privileged flag (full host access)"
    fi
done

echo "🎯 Starting Exegol container: ${NAME}"
echo ""

# Check if HTB VPN is connected
if ip addr show tun0 &>/dev/null; then
    echo "✅ HTB VPN detected (tun0 interface up)"
    ip addr show tun0 | grep -E "inet " | awk '{print "   IP: "$2}'
else
    echo "⚠️  No VPN detected - connect first with: ./htb-vpn.sh your-lab.ovpn"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
fi

echo ""
echo "🐳 Launching Exegol (this may take a moment on first run)..."
echo "   Workspace: ${WORKSPACE}"

# Create separate container history file if it doesn't exist
CONTAINER_HISTORY="${HOME}/docker/exegol-workspace/.exegol_history"
touch "${CONTAINER_HISTORY}"

if $USE_PRIVILEGED; then
    # Full privileged mode (use only if absolutely necessary)
    echo "   Mode: PRIVILEGED (full access)"
    echo ""
    docker run -it --rm \
        --name "${NAME}" \
        --hostname "${NAME}" \
        --network host \
        --privileged \
        -v "${WORKSPACE}:/workspace" \
        -v "${CONTAINER_HISTORY}:/root/.zsh_history" \
        -e DISPLAY="${DISPLAY:-:0}" \
        -e TERM="${TERM:-xterm-256color}" \
        ghcr.io/ThePorgs/Exegol-images:full
else
    # SECURITY HARDENED: Specific capabilities instead of --privileged (Critical Fix #3)
    # These capabilities cover most pentest activities:
    # - NET_ADMIN: Network configuration (required for nmap, arp scans, etc.)
    # - NET_RAW: Raw sockets (required for ping, nmap SYN scans, etc.)
    # - SYS_PTRACE: Process tracing (required for debugging, some exploits)
    # - DAC_READ_SEARCH: Bypass file read permission checks
    # - SETUID/SETGID: Change user/group IDs (some tools need this)
    echo "   Mode: Hardened (specific capabilities only)"
    # SECURITY WARNING: AppArmor/seccomp disabled (HIGH-5 fix - required for pentest tools)
    echo ""
    echo -e "   \033[1;33m⚠️  WARNING: Running with disabled security policies (AppArmor/seccomp)\033[0m"
    echo -e "   \033[1;33m   Required for pentest tools - only run in isolated network environments\033[0m"
    echo ""
    docker run -it --rm \
        --name "${NAME}" \
        --hostname "${NAME}" \
        --network host \
        --cap-drop=ALL \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        --cap-add=SYS_PTRACE \
        --cap-add=DAC_READ_SEARCH \
        --cap-add=SETUID \
        --cap-add=SETGID \
        --cap-add=MKNOD \
        --cap-add=AUDIT_WRITE \
        --security-opt apparmor=unconfined \
        --security-opt seccomp=unconfined \
        -v "${WORKSPACE}:/workspace" \
        -v "${CONTAINER_HISTORY}:/root/.zsh_history" \
        -v "${HOME}/.zsh_history:/root/.host_zsh_history:ro" \
        -e DISPLAY="${DISPLAY:-:0}" \
        -e TERM="${TERM:-xterm-256color}" \
        ghcr.io/ThePorgs/Exegol-images:full
fi

echo ""
echo "👋 Exegol session ended."
echo ""
echo "💡 If you encountered permission issues with specific tools, try:"
echo "   ./exegol-htb.sh ${NAME} --privileged"
EOF

  # htb-vpn.sh
  cat >"${DOCKER_DIR}/htb-vpn.sh" <<'EOF'
#!/usr/bin/env bash
# Connect to HTB VPN
# Usage: ./htb-vpn.sh [path/to/ovpn] [start|stop|status]

OVPN_FILE="${1:-${HOME}/htb/lab.ovpn}"
ACTION="${2:-start}"

case "$ACTION" in
    start)
        if [ ! -f "${OVPN_FILE}" ]; then
            echo "❌ OVPN file not found: ${OVPN_FILE}"
            echo ""
            echo "Usage: ./htb-vpn.sh /path/to/your.ovpn"
            echo ""
            echo "Available OVPN files in ~/htb:"
            ls -la "${HOME}/htb/"*.ovpn 2>/dev/null || echo "  (none found)"
            exit 1
        fi

        # SECURITY: Enforce restrictive permissions on OVPN file (MEDIUM-7 fix)
        # VPN files may contain credentials
        OVPN_PERMS=$(stat -c %a "${OVPN_FILE}" 2>/dev/null)
        if [ "$OVPN_PERMS" != "600" ]; then
            echo "🔒 Securing OVPN file permissions (was ${OVPN_PERMS}, setting to 600)"
            chmod 600 "${OVPN_FILE}"
        fi

        # Kill existing OpenVPN
        sudo pkill -f "openvpn.*htb" 2>/dev/null || true

        echo "🔌 Connecting to HTB VPN..."
        echo "   Config: ${OVPN_FILE}"

        sudo openvpn --config "${OVPN_FILE}" --daemon --log /tmp/htb-vpn.log

        # Wait for connection
        for i in {1..10}; do
            if ip addr show tun0 &>/dev/null; then
                echo ""
                echo "✅ Connected!"
                ip addr show tun0 | grep -E "inet " | awk '{print "   VPN IP: "$2}'
                exit 0
            fi
            sleep 1
            echo -n "."
        done

        echo ""
        echo "❌ Connection may have failed. Check: tail -f /tmp/htb-vpn.log"
        ;;

    stop)
        echo "🔌 Disconnecting HTB VPN..."
        sudo pkill -f "openvpn" 2>/dev/null || true
        echo "✅ Disconnected"
        ;;

    status)
        if ip addr show tun0 &>/dev/null; then
            echo "✅ VPN Connected"
            ip addr show tun0 | grep -E "inet " | awk '{print "   VPN IP: "$2}'
        else
            echo "❌ VPN Not Connected"
        fi
        ;;

    *)
        echo "Usage: ./htb-vpn.sh [ovpn-file] [start|stop|status]"
        ;;
esac
EOF

  # security-check.sh - Verification script from security audit
  cat >"${DOCKER_DIR}/security-check.sh" <<'EOF'
#!/usr/bin/env bash
# Security verification script based on SECURITY-AUDIT.md recommendations

echo "🔒 Docker Security Verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

PASS=0
WARN=0
FAIL=0

check_pass() { echo -e "  ✅ $1"; ((PASS++)); }
check_warn() { echo -e "  ⚠️  $1"; ((WARN++)); }
check_fail() { echo -e "  ❌ $1"; ((FAIL++)); }

# Check 1: Docker socket proxy
echo "1. Docker Socket Security"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q docker-socket-proxy; then
    check_pass "Docker socket proxy is running"
else
    check_fail "Docker socket proxy not running - Traefik has direct socket access"
fi

# Check 2: Secrets in environment variables
echo ""
echo "2. Secrets Management"
LEAKED_SECRETS=$(docker ps -q 2>/dev/null | xargs -r docker inspect --format '{{.Name}} {{range .Config.Env}}{{.}} {{end}}' 2>/dev/null | grep -iE "(password|secret|key|token)=" | grep -v "WEBUI_SECRET_KEY=\${" | head -5)
if [ -z "$LEAKED_SECRETS" ]; then
    check_pass "No hardcoded secrets found in container environment"
else
    check_fail "Secrets found in container environment (check .env files):"
    echo "$LEAKED_SECRETS" | head -3 | sed 's/^/       /'
fi

# Check 3: .env file permissions
echo ""
echo "3. Secret File Permissions"
for envfile in ~/docker/*/.env; do
    if [ -f "$envfile" ]; then
        PERMS=$(stat -c %a "$envfile" 2>/dev/null)
        if [ "$PERMS" = "600" ]; then
            check_pass "$(basename $(dirname $envfile))/.env has correct permissions (600)"
        else
            check_warn "$(basename $(dirname $envfile))/.env has permissions $PERMS (should be 600)"
        fi
    fi
done

# Check 4: Container security options
echo ""
echo "4. Container Security Options"
for container in traefik ollama open-webui; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        NO_NEW_PRIV=$(docker inspect "$container" --format '{{.HostConfig.SecurityOpt}}' 2>/dev/null | grep -c "no-new-privileges")
        if [ "$NO_NEW_PRIV" -gt 0 ]; then
            check_pass "$container has no-new-privileges"
        else
            check_warn "$container missing no-new-privileges"
        fi
    fi
done

# Check 5: Resource limits
echo ""
echo "5. Resource Limits"
for container in traefik ollama open-webui; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        MEM_LIMIT=$(docker inspect "$container" --format '{{.HostConfig.Memory}}' 2>/dev/null)
        if [ "$MEM_LIMIT" != "0" ] && [ -n "$MEM_LIMIT" ]; then
            MEM_MB=$((MEM_LIMIT / 1024 / 1024))
            check_pass "$container has memory limit (${MEM_MB}MB)"
        else
            check_warn "$container has no memory limit"
        fi
    fi
done

# Check 6: Image Versions
echo ""
echo "6. Image Versions"
for container in traefik ollama open-webui; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        IMAGE=$(docker inspect "$container" --format '{{.Config.Image}}' 2>/dev/null)
        if echo "$IMAGE" | grep -qE ":latest$|:main$"; then
            check_warn "$container uses unpinned tag: $IMAGE"
        else
            check_pass "$container uses pinned version: $IMAGE"
        fi
    fi
done

# Check 7: Traefik dashboard auth
echo ""
echo "7. Traefik Dashboard Authentication"
if [ -f ~/docker/traefik/dynamic/dashboard-auth.yml ]; then
    check_pass "Traefik dashboard auth middleware configured"
else
    check_fail "Traefik dashboard auth not configured"
fi

# Check 8: Health checks
echo ""
echo "8. Health Checks"
for container in traefik ollama open-webui; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
        HEALTH=$(docker inspect "$container" --format '{{.State.Health.Status}}' 2>/dev/null)
        if [ -n "$HEALTH" ] && [ "$HEALTH" != "<no value>" ]; then
            check_pass "$container has health check ($HEALTH)"
        else
            check_warn "$container has no health check"
        fi
    fi
done

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Summary: $PASS passed, $WARN warnings, $FAIL failed"
echo ""

if [ $FAIL -gt 0 ]; then
    echo "❌ Security issues detected - review and fix before production use"
    exit 1
elif [ $WARN -gt 0 ]; then
    echo "⚠️  Some warnings - review recommendations"
    exit 0
else
    echo "✅ All security checks passed!"
    exit 0
fi
EOF

  # Make all scripts executable
  chmod +x "${DOCKER_DIR}"/*.sh

  log "Helper scripts created (including security-check.sh)"

  # ---------------------------------------------------------------------------
  # AI Dev Stack Installer
  # ---------------------------------------------------------------------------
  info "AI Dev Stack installer..."

  cat >"${USER_HOME}/install-ai-dev-stack.sh" <<'AIDEV_EOF'
#!/usr/bin/env bash
# =============================================================================
# AI Dev Stack Installer
# Install AI coding assistants: Claude Code, OpenCode, Goose, LLM, Fabric
# Run anytime to install or update to latest versions
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# -----------------------------------------------------------------------------
# Installation functions
# -----------------------------------------------------------------------------

install_claude() {
    info "Installing/updating Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
    log "Claude Code installed/updated"
    echo "    Run: claude login"
}

install_opencode() {
    info "Installing/updating OpenCode..."
    curl -fsSL https://opencode.ai/install | bash
    log "OpenCode installed/updated"
    echo "    Set: export ANTHROPIC_API_KEY=your-key"
}

install_goose() {
    info "Installing/updating Goose..."
    curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | CONFIGURE=false bash
    log "Goose installed/updated"
    echo "    Run: goose configure"
}

install_llm() {
    info "Installing/updating LLM..."
    
    # Ensure pipx is installed
    if ! command -v pipx &>/dev/null; then
        info "Installing pipx first..."
        pip install --user pipx --break-system-packages 2>/dev/null || pip install --user pipx
        pipx ensurepath
        export PATH="$HOME/.local/bin:$PATH"
    fi
    
    if command -v llm &>/dev/null; then
        pipx upgrade llm 2>/dev/null || pipx install llm --force
    else
        pipx install llm
    fi
    
    log "LLM installed/updated"
    echo "    Run: llm keys set openai"
    echo "    Docs: https://llm.datasette.io"
}

install_fabric() {
    info "Installing/updating Fabric..."
    curl -fsSL https://raw.githubusercontent.com/danielmiessler/fabric/main/scripts/installer/install.sh | bash
    log "Fabric installed/updated"
    echo "    Run: fabric --setup"
    echo "    Docs: https://github.com/danielmiessler/fabric"
}

install_all() {
    echo ""
    install_claude
    echo ""
    install_opencode
    echo ""
    install_goose
    echo ""
    install_llm
    echo ""
    install_fabric
    echo ""
    log "All AI tools installed/updated!"
}

update_all() {
    info "Updating all installed tools..."
    echo ""
    
    if command -v claude &>/dev/null; then
        install_claude
        echo ""
    fi
    
    if command -v opencode &>/dev/null; then
        install_opencode
        echo ""
    fi
    
    if command -v goose &>/dev/null; then
        install_goose
        echo ""
    fi
    
    if command -v llm &>/dev/null; then
        install_llm
        echo ""
    fi
    
    if command -v fabric &>/dev/null; then
        install_fabric
        echo ""
    fi
    
    log "All installed tools updated!"
}

show_status() {
    echo ""
    echo -e "${CYAN}AI Dev Stack Status${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if command -v claude &>/dev/null; then
        echo -e "Claude Code:  ${GREEN}installed${NC} ($(which claude))"
    else
        echo -e "Claude Code:  ${RED}not installed${NC}"
    fi
    
    if command -v opencode &>/dev/null; then
        echo -e "OpenCode:     ${GREEN}installed${NC} ($(which opencode))"
    else
        echo -e "OpenCode:     ${RED}not installed${NC}"
    fi
    
    if command -v goose &>/dev/null; then
        echo -e "Goose:        ${GREEN}installed${NC} ($(which goose))"
    else
        echo -e "Goose:        ${RED}not installed${NC}"
    fi
    
    if command -v llm &>/dev/null; then
        echo -e "LLM:          ${GREEN}installed${NC} ($(which llm))"
    else
        echo -e "LLM:          ${RED}not installed${NC}"
    fi
    
    if command -v fabric &>/dev/null; then
        echo -e "Fabric:       ${GREEN}installed${NC} ($(which fabric))"
    else
        echo -e "Fabric:       ${RED}not installed${NC}"
    fi
    echo ""
}

show_menu() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}         AI Dev Stack Installer              ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  1) Install Claude Code   (Anthropic)"
    echo "  2) Install OpenCode      (Open-source, multi-provider)"
    echo "  3) Install Goose         (Block's AI agent)"
    echo "  4) Install LLM           (Datasette CLI)"
    echo "  5) Install Fabric        (AI prompts framework)"
    echo ""
    echo "  a) Install ALL"
    echo "  u) Update installed tools"
    echo "  s) Show status"
    echo "  q) Quit"
    echo ""
    echo -n "Select option: "
}

interactive_menu() {
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1) echo ""; install_claude ;;
            2) echo ""; install_opencode ;;
            3) echo ""; install_goose ;;
            4) echo ""; install_llm ;;
            5) echo ""; install_fabric ;;
            a|A) install_all ;;
            u|U) update_all ;;
            s|S) show_status ;;
            q|Q) echo ""; exit 0 ;;
            *) warn "Invalid option" ;;
        esac
        
        echo ""
        echo -n "Press Enter to continue..."
        read -r
    done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

show_help() {
    echo "Usage: $0 [option]"
    echo ""
    echo "Options:"
    echo "  --claude      Install/update Claude Code"
    echo "  --opencode    Install/update OpenCode"
    echo "  --goose       Install/update Goose"
    echo "  --llm         Install/update LLM (Datasette)"
    echo "  --fabric      Install/update Fabric"
    echo "  --all         Install all tools"
    echo "  --update      Update all installed tools"
    echo "  --status      Show installation status"
    echo "  --help        Show this help"
    echo ""
    echo "Run without arguments for interactive menu."
}

# Parse arguments
if [[ $# -eq 0 ]]; then
    interactive_menu
else
    case "$1" in
        --claude)   install_claude ;;
        --opencode) install_opencode ;;
        --goose)    install_goose ;;
        --llm)      install_llm ;;
        --fabric)   install_fabric ;;
        --all)      install_all ;;
        --update)   update_all ;;
        --status)   show_status ;;
        --help|-h)  show_help ;;
        *)          error "Unknown option: $1. Use --help for usage." ;;
    esac
    
    # Reload shell config to update PATH
    echo ""
    info "Reloading shell to update PATH..."
    exec $SHELL
fi
AIDEV_EOF

  chmod +x "${USER_HOME}/install-ai-dev-stack.sh"

  log "AI Dev Stack installer created"
fi # End of docker stack configuration block

# ---------------------------------------------------------------------------
# Exegol Image Pre-pull (Optional)
# ---------------------------------------------------------------------------
echo ""
if $EXISTING_EXEGOL; then
  log "Exegol image already exists"
else
  info "Exegol image not found locally"
  read -p "Pre-pull Exegol image now? (~15GB, takes a while) (y/N) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    info "Pulling Exegol image (this may take 10-30 minutes)..."
    docker pull ghcr.io/ThePorgs/Exegol-images:full &&
      log "Exegol image pulled successfully" ||
      warn "Exegol pull failed - will be pulled on first use"
  else
    info "Skipping Exegol pre-pull (will download on first use)"
  fi
fi

# =============================================================================
# PHASE 9: Shell Configuration
# =============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}PHASE 9: Shell Configuration${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Install Oh-My-Zsh
if $EXISTING_ZSH; then
  log "Oh-My-Zsh already installed for ${NEW_USER}"
else
  info "Installing Oh-My-Zsh..."
  su - "${NEW_USER}" -c 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended' 2>/dev/null || true
  log "Oh-My-Zsh installed"
fi

# Update .zshrc (backup existing if present)
if [ -f "${USER_HOME}/.zshrc" ]; then
  cp "${USER_HOME}/.zshrc" "${USER_HOME}/.zshrc.backup.$(date +%Y%m%d%H%M%S)"
  info "Existing .zshrc backed up"
fi

info "Configuring shell aliases..."

cat >"${USER_HOME}/.zshrc" <<'EOF'
# Oh-My-Zsh
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git docker docker-compose)
source $ZSH/oh-my-zsh.sh

# ─── mise (version manager) ──────────────────────────────────────────────────
export PATH="/opt/mise:$PATH"
if command -v mise &>/dev/null; then
    eval "$(mise activate zsh)"
fi

# ─── Docker Aliases ──────────────────────────────────────────────────────────
alias d="docker"
alias dc="docker compose"
alias dps="docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
alias dpsa="docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
alias dlog="docker logs -f"
alias dex="docker exec -it"
alias dprune="docker system prune -af"

# ─── Git Aliases ─────────────────────────────────────────────────────────────
alias lg="lazygit"
alias gs="git status"
alias gp="git pull"
alias gP="git push"

# ─── Editor ──────────────────────────────────────────────────────────────────
alias vim="nvim"
alias vi="nvim"

# ─── DevBox Shortcuts ────────────────────────────────────────────────────────
alias start-all="~/docker/start-all.sh"
alias stop-all="~/docker/stop-all.sh"
alias status="~/docker/status.sh"
alias exegol="~/docker/exegol-htb.sh"
alias htb-vpn="~/docker/htb-vpn.sh"
alias security-check="~/docker/security-check.sh"

# ─── Tailscale ───────────────────────────────────────────────────────────────
alias ts="tailscale"
alias tsip="tailscale ip -4"
alias tsstatus="tailscale status"
alias tsup="sudo tailscale up"
alias tsdown="sudo tailscale down"

# ─── Navigation ──────────────────────────────────────────────────────────────
alias dock="cd ~/docker"
alias proj="cd ~/projects"
alias htb="cd ~/htb"

# ─── Utilities ───────────────────────────────────────────────────────────────
alias ll="ls -lahF"
alias la="ls -A"
alias l="ls -CF"
alias s="cd .."
alias ..="cd .."
alias ...="cd ../.."
alias grep="grep --color=auto"

# ─── History ─────────────────────────────────────────────────────────────────
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS

# ─── Welcome Message ─────────────────────────────────────────────────────────
echo ""
echo "🖥️  DevBox Ready (Security Hardened)"
echo "   Quick commands: start-all | stop-all | status | security-check"
echo "   Pentest:        exegol | htb-vpn"
echo ""
EOF

log "Shell configured with aliases"

# =============================================================================
# PHASE 10: Fix Ownership & Final Steps
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
else
  log "SSH restart not needed"
fi

log "Setup complete!"

# =============================================================================
# SUMMARY
# =============================================================================
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo -e "${GREEN}"
cat <<'EOF'
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║                        ✅ SETUP COMPLETE!                                 ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# SECURITY: Write credentials to secure file instead of terminal
CREDS_FILE="${USER_HOME}/.devbox-credentials"
cat >"${CREDS_FILE}" <<EOF
================================================================================
DevBox Credentials (Generated: $(date))
================================================================================

User: ${NEW_USER}
$(if ! $EXISTING_USER; then echo "Backup Password: ${DEV_PASSWORD}"; else echo "Backup Password: (existing user - password unchanged)"; fi)

SERVICE CREDENTIALS
-------------------
Open WebUI Secret:      ${OPENWEBUI_SECRET}
Traefik Dashboard:      ${TRAEFIK_USER} / ${TRAEFIK_PASS}

IMPORTANT:
- These credentials are also stored in ~/docker/*/.env files
- DELETE THIS FILE AFTER RECORDING CREDENTIALS SECURELY
- Use a password manager to store these values

================================================================================
EOF
chmod 600 "${CREDS_FILE}"
chown "${NEW_USER}:${NEW_USER}" "${CREDS_FILE}"

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}CREDENTIALS${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}Credentials saved to: ${CREDS_FILE}${NC}"
echo ""
echo "  View credentials:   cat ${CREDS_FILE}"
echo "  Delete after use:   rm ${CREDS_FILE}"
echo ""
echo -e "  ${RED}⚠️  DELETE credentials file after recording in password manager!${NC}"
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}NEXT STEPS${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "1️⃣  TEST SSH (from a NEW terminal - don't close this one!):"
echo ""
echo "    ssh -p ${SSH_PORT} ${NEW_USER}@$(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')"
echo ""
echo "2️⃣  AUTHENTICATE TAILSCALE (as root or with sudo):"
echo ""
echo "    sudo tailscale up --accept-routes --advertise-tags=tag:devbox"
echo ""
echo "    → Open the URL in browser to authenticate"
echo "    → Enable MagicDNS: https://login.tailscale.com/admin/dns"
echo ""
echo "3️⃣  START SERVICES (as ${NEW_USER}):"
echo ""
echo "    cd ~/docker && ./start-all.sh"
echo ""
echo "4️⃣  INSTALL AI DEV STACK:"
echo ""
echo "    ./install-ai-dev-stack.sh"
echo ""
echo "5️⃣  PULL OLLAMA MODELS:"
echo ""
echo "    docker exec -it ollama ollama pull llama3.2"
echo "    docker exec -it ollama ollama pull codellama"
echo ""
echo "6️⃣  VERIFY SECURITY HARDENING:"
echo ""
echo "    ./security-check.sh"
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}ACCESS SERVICES${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Add this line to /etc/hosts on your LAPTOP (after Tailscale connected):"
echo ""
echo "    TAILSCALE_IP  ai.internal traefik.internal ollama.internal"
echo ""
echo "Then access:"
echo "    http://ai.internal        → Open WebUI (create admin account on first visit)"
echo "    http://traefik.internal   → Traefik Dashboard (user: ${TRAEFIK_USER})"
echo "    http://ollama.internal    → Ollama API"
echo ""
echo -e "${CYAN}SECURITY NOTES:${NC}"
echo "    • Passwords are stored in ~/docker/*/.env files (600 permissions)"
echo "    • Disable Open WebUI signup after creating admin: edit .env, set ENABLE_SIGNUP=false"
echo "    • All containers run with security hardening (no-new-privileges, cap_drop)"
echo "    • Traefik uses docker-socket-proxy to limit Docker API exposure"
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}HTB / PENTEST WORKFLOW${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "    # Connect VPN"
echo "    ./htb-vpn.sh ~/htb/your-lab.ovpn"
echo ""
echo "    # Start Exegol (full pentest toolkit)"
echo "    ./exegol-htb.sh"
echo ""
echo "    # Inside Exegol: nmap, metasploit, etc. have HTB network access"
echo ""

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Setup completed in ${DURATION} seconds"
echo -e "${RED}⚠️  DO NOT close this terminal until you verify SSH access!${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
