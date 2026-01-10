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
