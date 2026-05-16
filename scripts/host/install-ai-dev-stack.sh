#!/usr/bin/env bash
# =============================================================================
# DevBox v3 — AI Dev Stack Installer
# =============================================================================
# User-invoked installer for AI coding tools: Claude Code, OpenCode, Goose,
# LLM, Fabric. Runs as the `dev` user (NOT as root), installs into user-level
# prefixes, and can be re-run to update.
#
# Trust boundary (see ARCHITECTURE.md):
#   - setup.sh's bootstrap dependencies (Tailscale, mise, rust, bun, etc.)
#     are pinned via fetch_and_verify + scripts/lib/download-manifest.sh
#   - THIS script's dependencies are AI coding tools distributed by their
#     own vendors (Anthropic, Block, Datasette, Fabric maintainers). They
#     ship mutable curl|sh installers that are signed/updated frequently.
#     Pinning them would create friction without meaningful security gain
#     because the binaries they fetch carry their own signatures.
#   - The operator opts in to each tool explicitly via this menu.
#
# Source of truth: /home/dev/docker/devbox/scripts/host/install-ai-dev-stack.sh
# Installed to:    ~/docker/install-ai-dev-stack.sh (rsync from scripts/host/)
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[OK]${NC} $1"; }
info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# -----------------------------------------------------------------------------
# Installation functions (vendor-signed binaries; see trust-boundary note above)
# -----------------------------------------------------------------------------

install_claude() {
  info "Installing/updating Claude Code..."
  curl -fsSL https://claude.ai/install.sh | bash
  log "Claude Code installed/updated"
  echo "    Next:  claude login"
}

install_opencode() {
  info "Installing/updating OpenCode..."
  curl -fsSL https://opencode.ai/install | bash
  log "OpenCode installed/updated"
  echo "    Next:  export ANTHROPIC_API_KEY=<your-key>"
}

install_goose() {
  info "Installing/updating Goose..."
  curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | CONFIGURE=false bash
  log "Goose installed/updated"
  echo "    Next:  goose configure"
}

install_llm() {
  info "Installing/updating LLM..."

  # Ensure pipx is available (user-level Python app installer)
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
  echo "    Next:  llm keys set openai"
  echo "    Docs:  https://llm.datasette.io"
}

install_fabric() {
  info "Installing/updating Fabric..."
  curl -fsSL https://raw.githubusercontent.com/danielmiessler/fabric/main/scripts/installer/install.sh | bash
  log "Fabric installed/updated"
  echo "    Next:  fabric --setup"
  echo "    Docs:  https://github.com/danielmiessler/fabric"
}

install_all() {
  echo ""
  install_claude; echo ""
  install_opencode; echo ""
  install_goose; echo ""
  install_llm; echo ""
  install_fabric; echo ""
  log "All AI tools installed/updated!"
}

update_all() {
  info "Updating all installed tools..."
  echo ""
  command -v claude   &>/dev/null && { install_claude;   echo ""; }
  command -v opencode &>/dev/null && { install_opencode; echo ""; }
  command -v goose    &>/dev/null && { install_goose;    echo ""; }
  command -v llm      &>/dev/null && { install_llm;      echo ""; }
  command -v fabric   &>/dev/null && { install_fabric;   echo ""; }
  log "All installed tools updated!"
}

show_status() {
  echo ""
  echo -e "${CYAN}AI Dev Stack Status${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  _row() {
    local name="$1" cmd="$2"
    if command -v "$cmd" &>/dev/null; then
      printf '%-13s %binstalled%b (%s)\n' "$name" "$GREEN" "$NC" "$(command -v "$cmd")"
    else
      printf '%-13s %bnot installed%b\n' "$name" "$RED" "$NC"
    fi
  }
  _row "Claude Code:" claude
  _row "OpenCode:"    opencode
  _row "Goose:"       goose
  _row "LLM:"         llm
  _row "Fabric:"      fabric
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
      1)   echo ""; install_claude ;;
      2)   echo ""; install_opencode ;;
      3)   echo ""; install_goose ;;
      4)   echo ""; install_llm ;;
      5)   echo ""; install_fabric ;;
      a|A) install_all ;;
      u|U) update_all ;;
      s|S) show_status ;;
      q|Q) echo ""; exit 0 ;;
      *)   warn "Invalid option" ;;
    esac
    echo ""
    echo -n "Press Enter to continue..."
    read -r
  done
}

show_help() {
  cat <<'HELP'
Usage: install-ai-dev-stack.sh [option]

Options:
  --claude      Install/update Claude Code
  --opencode    Install/update OpenCode
  --goose       Install/update Goose
  --llm         Install/update LLM (Datasette)
  --fabric      Install/update Fabric
  --all         Install all tools
  --update      Update all installed tools
  --status      Show installation status
  --help        Show this help

Run without arguments for interactive menu.

Trust note: this script installs vendor-distributed AI coding tools via
their official curl|sh installers. These vendors ship their own signed
binaries; pinning the installer SHAs would create churn without
meaningful security gain. The operator opts into each tool explicitly.
For the hardened fetch_and_verify pattern used by setup.sh itself,
see ARCHITECTURE.md.
HELP
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

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
  exec "${SHELL:-/bin/bash}"
fi
