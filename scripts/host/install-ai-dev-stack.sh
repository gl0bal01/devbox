#!/usr/bin/env bash
# Install or update AI coding CLIs for the current user through mise, which
# verifies each download (checksums, plus cosign / SLSA / GitHub attestations
# where the vendor publishes them). Tools land in ~/.config/mise/config.toml.
#
# Usage: install-ai-dev-stack.sh [--all | --update | --status | <tool>...]
#   tools: claude opencode goose llm fabric
set -euo pipefail

declare -A TOOLS=(
    [claude]="aqua:anthropics/claude-code"
    [opencode]="aqua:anomalyco/opencode"
    [goose]="aqua:block/goose"
    [llm]="pypi:llm"
    [fabric]="github:danielmiessler/fabric"
)
ORDER=(claude opencode goose llm fabric)

command -v mise >/dev/null 2>&1 || { echo "mise not found: run setup.sh first." >&2; exit 1; }

install_tool() {
    local name="$1"
    [ -n "${TOOLS[${name}]:-}" ] || { echo "Unknown tool: ${name} (choose: ${ORDER[*]})" >&2; return 1; }
    echo "-> ${name} (${TOOLS[${name}]})"
    mise use --global --yes "${TOOLS[${name}]}@latest"
}

status() {
    local name
    for name in "${ORDER[@]}"; do
        printf '  %-9s %s\n' "${name}" "$(mise current "${TOOLS[${name}]}" 2>/dev/null || echo '-')"
    done
}

case "${1:---help}" in
    --all)    for t in "${ORDER[@]}"; do install_tool "${t}"; done ;;
    --update) mise upgrade --yes "${TOOLS[@]}" ;;
    --status) status ;;
    -h|--help)
        sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
        echo ""
        status
        ;;
    *)        for t in "$@"; do install_tool "${t}"; done ;;
esac
