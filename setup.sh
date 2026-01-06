#!/usr/bin/env bash
# =============================================================================
# DEVBOX FULL SETUP SCRIPT v2.0
# =============================================================================
# Remote Dev/Pentest/AI Station - Production Ready
#
# Target: Ubuntu 24.04 with Docker pre-installed (Hostinger Docker image)
# Stack:  Tailscale + Traefik (internal) + Ollama + Claude Code + Exegol
#
# Features:
#   - User creation with SSH key auth
#   - SSH hardening (custom port, key-only)
#   - UFW firewall
#   - Tailscale VPN (zero public exposure)
#   - Traefik reverse proxy (internal routing)
#   - Ollama + Open WebUI (local AI)
#   - code-server (VS Code in browser)
#   - Exegol (pentest container)
#   - Claude Code CLI
#   - mise (polyglot version manager)
#
# Usage:
#   1. Edit CONFIGURATION section below
#   2. Run as root: ./setup.sh
#   3. Follow post-install instructions
#
# Author: DevOps Assistant
# Date: January 2026
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION - EDIT THESE VALUES
# =============================================================================

# User settings
NEW_USER="dev"
USER_EMAIL="admin@example.com"           # Used for Let's Encrypt (future)

# SSH settings
SSH_PORT="5522"                          # Non-standard port (security)
SSH_PUBLIC_KEY="ssh-ed25519 AAAA..."     # Paste your public key here, or leave empty to add manually

# Passwords for services (auto-generated if empty)
CODE_SERVER_PASSWORD=""                  # Leave empty to auto-generate
OPENWEBUI_SECRET=""                      # Leave empty to auto-generate

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
log()   { echo -e "${GREEN}[✓]${NC} $1"; }
info()  { echo -e "${BLUE}[i]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# Password generator
generate_password() {
    openssl rand -base64 18 | tr -d '/+='
}

# Generate passwords if not set
[ -z "$CODE_SERVER_PASSWORD" ] && CODE_SERVER_PASSWORD=$(generate_password)
[ -z "$OPENWEBUI_SECRET" ] && OPENWEBUI_SECRET=$(generate_password)
DEV_PASSWORD=$(generate_password)

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
cat << 'EOF'
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
║     Tailscale + Traefik + Ollama + Claude Code + Exegol                   ║
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
        echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${NEW_USER}"
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
    echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${NEW_USER}"
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
        echo "${SSH_PUBLIC_KEY}" >> "${USER_HOME}/.ssh/authorized_keys"
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
    cat > /etc/ssh/sshd_config.d/99-hardening.conf << EOF
# DevBox SSH Hardening
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
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

info "Configuring UFW firewall..."
ufw --force reset >/dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp comment "SSH"
ufw --force enable

log "Firewall configured (only SSH:${SSH_PORT} open)"

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

cat > /etc/profile.d/mise.sh << 'EOF'
if [ -z "$SUDO_USER" ] && command -v mise &>/dev/null; then
    eval "$(mise activate bash)"
fi
EOF


# Activate for dev user's zsh
if [ -d "${USER_HOME}" ]; then
    mkdir -p "${USER_HOME}/.config/mise"

    # Add to .zshrc if not already present
    if ! grep -q "mise activate" "${USER_HOME}/.zshrc" 2>/dev/null; then
        cat >> "${USER_HOME}/.zshrc" << 'EOF'

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
        mkdir -p "${DOCKER_DIR}"/{traefik/dynamic,ollama-openwebui,code-server,exegol-workspace}
        mkdir -p "${PROJECTS_DIR}"
        mkdir -p "${HTB_DIR}"
    else
        EXISTING_STACK=false
    fi
fi

if ! $EXISTING_STACK; then
    info "Creating directory structure..."
    mkdir -p "${DOCKER_DIR}"/{traefik/dynamic,ollama-openwebui,code-server,exegol-workspace}
    mkdir -p "${PROJECTS_DIR}"
    mkdir -p "${HTB_DIR}"

# ---------------------------------------------------------------------------
# Traefik (Internal Reverse Proxy)
# ---------------------------------------------------------------------------
info "Creating Traefik configuration..."

cat > "${DOCKER_DIR}/traefik/docker-compose.yml" << 'EOF'
services:
  traefik:
    image: traefik:v3.6
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "80:80"      # Safe: UFW blocks public, only Tailscale can reach
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./dynamic:/etc/traefik/dynamic:ro
    networks:
      - proxy-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(`traefik.internal`)"
      - "traefik.http.routers.traefik.service=api@internal"

networks:
  proxy-net:
    external: true
EOF

cat > "${DOCKER_DIR}/traefik/traefik.yml" << 'EOF'
global:
  checkNewVersion: true
  sendAnonymousUsage: false

entryPoints:
  web:
    address: ":80"

providers:
  docker:
    exposedByDefault: false
    network: proxy-net
  file:
    directory: /etc/traefik/dynamic
    watch: true

api:
  dashboard: true
  insecure: true    # Safe: internal only via Tailscale

log:
  level: INFO

accessLog: {}
EOF

# Dynamic config example
cat > "${DOCKER_DIR}/traefik/dynamic/.gitkeep" << 'EOF'
# Place dynamic configuration files here
# Example: middlewares, TLS settings, etc.
EOF

log "Traefik configured"

# ---------------------------------------------------------------------------
# Ollama + Open WebUI
# ---------------------------------------------------------------------------
info "Creating Ollama + Open WebUI configuration..."

cat > "${DOCKER_DIR}/ollama-openwebui/docker-compose.yml" << EOF
services:
  ollama:
    image: ollama/ollama:latest
    # mem_limit: 24gb <- Add this for Hostinger KVM 8 and fast GGUF i1-Q4_K_M models
    container_name: ollama
    restart: unless-stopped
    volumes:
      - ./ollama-data:/root/.ollama
    ports:
      - "127.0.0.1:11434:11434"    # Localhost only for Claude Code
    networks:
      - proxy-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.ollama-api.rule=Host(\`ollama.internal\`)"
      - "traefik.http.services.ollama-api.loadbalancer.server.port=11434"
    # Uncomment if you have NVIDIA GPU + nvidia-container-toolkit:
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - driver: nvidia
    #           count: all
    #           capabilities: [gpu]

  openwebui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    depends_on:
      - ollama
    environment:
      - OLLAMA_BASE_URLS=http://ollama:11434
      - WEBUI_SECRET_KEY=${OPENWEBUI_SECRET}
      - ENABLE_SIGNUP=true
    volumes:
      - ./openwebui-data:/app/backend/data
    networks:
      - proxy-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.openwebui.rule=Host(\`ai.internal\`)"
      - "traefik.http.services.openwebui.loadbalancer.server.port=8080"

networks:
  proxy-net:
    external: true
EOF

log "Ollama + Open WebUI configured"

# ---------------------------------------------------------------------------
# Code-server
# ---------------------------------------------------------------------------
info "Creating code-server configuration..."

cat > "${DOCKER_DIR}/code-server/docker-compose.yml" << EOF
services:
  code-server:
    image: codercom/code-server:latest
    container_name: code-server
    restart: unless-stopped
    user: "1001:1001"
    environment:
      - PASSWORD=${CODE_SERVER_PASSWORD}
      - DEFAULT_WORKSPACE=/home/coder/project
    volumes:
      - ${PROJECTS_DIR}:/home/coder/project
      - ./config:/home/coder/.config
      - ./local:/home/coder/.local
    networks:
      - proxy-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.code.rule=Host(\`code.internal\`)"
      - "traefik.http.services.code.loadbalancer.server.port=8080"

networks:
  proxy-net:
    external: true
EOF

log "code-server configured"

# ---------------------------------------------------------------------------
# Helper Scripts
# ---------------------------------------------------------------------------
info "Creating helper scripts..."

# start-all.sh
cat > "${DOCKER_DIR}/start-all.sh" << 'EOF'
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

echo "🚀 Starting all services..."

echo "  → Traefik..."
cd traefik && docker compose up -d && cd ..

echo "  → Ollama + Open WebUI..."
cd ollama-openwebui && docker compose up -d && cd ..

echo "  → Code-server..."
cd code-server && docker compose up -d && cd ..

echo ""
echo "✅ All services started!"
echo ""
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
EOF

# stop-all.sh
cat > "${DOCKER_DIR}/stop-all.sh" << 'EOF'
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

echo "🛑 Stopping all services..."

for dir in code-server ollama-openwebui traefik; do
    if [ -d "$dir" ]; then
        echo "  → Stopping ${dir}..."
        cd "$dir" && docker compose down && cd ..
    fi
done

echo ""
echo "✅ All services stopped."
EOF

# status.sh
cat > "${DOCKER_DIR}/status.sh" << 'EOF'
#!/usr/bin/env bash
echo "📊 Docker Services Status"
echo ""
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "📡 Tailscale Status"
tailscale status 2>/dev/null || echo "  Tailscale not connected"
echo ""
echo "🌐 Access URLs (add to /etc/hosts on your laptop):"
TSIP=$(tailscale ip -4 2>/dev/null || echo "TAILSCALE_IP")
echo "  ${TSIP}  code.internal ai.internal traefik.internal ollama.internal"
EOF

# exegol-htb.sh
cat > "${DOCKER_DIR}/exegol-htb.sh" << 'EOF'
#!/usr/bin/env bash
# Start Exegol for HTB/pentest with host network (inherits VPN)
# Usage: ./exegol-htb.sh [container-name]

NAME="${1:-exegol-htb}"
WORKSPACE="${HOME}/docker/exegol-workspace"

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
echo ""

docker run -it --rm \
    --name "${NAME}" \
    --hostname "${NAME}" \
    --network host \
    --privileged \
    --cap-add=NET_ADMIN \
    --cap-add=SYS_PTRACE \
    -v "${WORKSPACE}:/workspace" \
    -v "${HOME}/.zsh_history:/root/.zsh_history" \
    -e DISPLAY="${DISPLAY:-:0}" \
    -e TERM="${TERM:-xterm-256color}" \
    ghcr.io/ThePorgs/Exegol-images:full

echo ""
echo "👋 Exegol session ended."
EOF

# htb-vpn.sh
cat > "${DOCKER_DIR}/htb-vpn.sh" << 'EOF'
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

# Make all scripts executable
chmod +x "${DOCKER_DIR}"/*.sh

log "Helper scripts created"

# ---------------------------------------------------------------------------
# Claude Code Installer
# ---------------------------------------------------------------------------
info "Creating Claude Code installer..."

cat > "${USER_HOME}/install-claude-code.sh" << 'EOF'
#!/usr/bin/env bash
# Install Claude Code CLI
# Run as your user (not root)

set -e

echo "🤖 Installing Claude Code..."
echo ""

# Ensure mise/node available
export PATH="/opt/mise:$PATH"
if command -v mise &>/dev/null; then
    eval "$(mise activate bash)"
fi

# Install Node.js if needed
if ! command -v node &>/dev/null; then
    echo "📦 Installing Node.js via mise..."
    mise use --global node@22
    eval "$(mise activate bash)"
fi

echo "📦 Installing Claude Code via npm..."
npm install -g @anthropic-ai/claude-code

echo ""
echo "✅ Claude Code installed!"
echo ""
echo "Next steps:"
echo "  1. Run: claude login"
echo "  2. Use:  claude 'your prompt here'"
echo ""
echo "Examples:"
echo "  claude 'explain this code'"
echo "  claude 'fix the bug in auth.py'"
echo "  claude 'write tests for utils.js'"
EOF

chmod +x "${USER_HOME}/install-claude-code.sh"

log "Claude Code installer created"
fi  # End of docker stack configuration block

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
        docker pull ghcr.io/ThePorgs/Exegol-images:full && \
            log "Exegol image pulled successfully" || \
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

cat > "${USER_HOME}/.zshrc" << 'EOF'
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
echo "🖥️  DevBox Ready"
echo "   Quick commands: start-all | stop-all | status | exegol | htb-vpn"
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
cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║                        ✅ SETUP COMPLETE!                                 ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}CREDENTIALS (SAVE THESE NOW!)${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  User:                 ${NEW_USER}"
if ! $EXISTING_USER; then
    echo "  Backup Password:      ${DEV_PASSWORD}"
else
    echo "  Backup Password:      (existing user - password unchanged)"
fi
echo "  code-server Password: ${CODE_SERVER_PASSWORD}"
echo "  Open WebUI Secret:    ${OPENWEBUI_SECRET}"
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
echo "4️⃣  INSTALL CLAUDE CODE:"
echo ""
echo "    ./install-claude-code.sh"
echo "    claude login"
echo ""
echo "5️⃣  PULL OLLAMA MODELS:"
echo ""
echo "    docker exec -it ollama ollama pull llama3.2"
echo "    docker exec -it ollama ollama pull codellama"
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}ACCESS SERVICES${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Add this line to /etc/hosts on your LAPTOP (after Tailscale connected):"
echo ""
echo "    TAILSCALE_IP  code.internal ai.internal traefik.internal ollama.internal"
echo ""
echo "Then access:"
echo "    http://code.internal      → VS Code (password: ${CODE_SERVER_PASSWORD})"
echo "    http://ai.internal        → Open WebUI (Ollama chat)"
echo "    http://traefik.internal   → Traefik Dashboard"
echo "    http://ollama.internal    → Ollama API"
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
