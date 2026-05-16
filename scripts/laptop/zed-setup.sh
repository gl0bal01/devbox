#!/usr/bin/env bash
# DevBox v3 — Zed Editor Remote Ollama Setup
#
# Configures Zed to call a remote Ollama server via Tailscale.
#
# v3 changes from v2 (F6 / Critic):
#   - MERGES the ollama config into existing ~/.config/zed/settings.json via
#     `jq -s '.[0] * .[1]'` instead of OVERWRITING the file. Previously, any
#     other Zed settings (themes, keybindings, language overrides) were
#     destroyed on every run.
#   - Idempotent: re-running this script does not change valid output.
#   - `set -euo pipefail` for safety.
#   - Requires `jq` (will fail loudly if missing).
#
# Usage:
#   export OLLAMA_SERVER_IP="100.x.x.x"   # Your server's Tailscale IP
#   bash scripts/laptop/zed-setup.sh

set -euo pipefail

if [ -z "${OLLAMA_SERVER_IP:-}" ]; then
  echo "Error: OLLAMA_SERVER_IP not set" >&2
  echo ""
  echo "Usage:"
  echo "  export OLLAMA_SERVER_IP=\"100.x.x.x\"   # Your server's Tailscale IP"
  echo "  bash $0"
  echo ""
  echo "Find your Tailscale IP:"
  echo "  ssh your-server \"tailscale ip -4\""
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required for safe JSON merging. Install it first:" >&2
  echo "  Ubuntu/Debian: sudo apt install jq" >&2
  echo "  macOS:         brew install jq" >&2
  exit 1
fi

ZED_CONFIG_DIR="$HOME/.config/zed"
ZED_CONFIG_FILE="$ZED_CONFIG_DIR/settings.json"

echo "Setting up Zed for remote Ollama access..."
echo "  Server IP:      $OLLAMA_SERVER_IP"
echo "  Config file:    $ZED_CONFIG_FILE"
echo ""

mkdir -p "$ZED_CONFIG_DIR"

# Build the ollama-overlay JSON. Use jq -n with --arg so the IP can never
# escape the JSON envelope.
OLLAMA_OVERLAY=$(jq -n --arg url "http://${OLLAMA_SERVER_IP}:11434" '
  {
    language_models: {
      ollama: {
        api_url: $url,
        low_speed_timeout_in_seconds: 120
      }
    },
    assistant: {
      version: "2",
      default_model: {
        provider: "ollama",
        model: "qwen3"
      }
    }
  }
')

if [ -f "$ZED_CONFIG_FILE" ]; then
  # Backup once per run with timestamp
  BACKUP_FILE="${ZED_CONFIG_FILE}.devbox-backup.$(date +%Y%m%d_%H%M%S)"
  cp "$ZED_CONFIG_FILE" "$BACKUP_FILE"
  echo "  Backup:         $BACKUP_FILE"

  # Validate the existing file is parseable JSON. Zed accepts JSONC but jq
  # does not — strip // and /* */ comments before merging.
  STRIPPED=$(sed -e 's|//.*$||' -e '/\/\*/,/\*\//d' "$ZED_CONFIG_FILE")
  if ! printf '%s' "$STRIPPED" | jq empty 2>/dev/null; then
    echo "Warning: $ZED_CONFIG_FILE contains JSONC features that jq cannot parse." >&2
    echo "         Falling back to a new file. Your old config is at $BACKUP_FILE." >&2
    printf '%s\n' "$OLLAMA_OVERLAY" >"$ZED_CONFIG_FILE"
  else
    # Deep-merge the existing settings with the ollama overlay. The overlay
    # wins on conflicts (* operator merges right-into-left in jq).
    MERGED=$(printf '%s\n%s\n' "$STRIPPED" "$OLLAMA_OVERLAY" | jq -s '.[0] * .[1]')
    printf '%s\n' "$MERGED" >"${ZED_CONFIG_FILE}.tmp.$$"
    mv "${ZED_CONFIG_FILE}.tmp.$$" "$ZED_CONFIG_FILE"
    echo "  Merged ollama config into existing settings"
  fi
else
  printf '%s\n' "$OLLAMA_OVERLAY" >"$ZED_CONFIG_FILE"
  echo "  Created new $ZED_CONFIG_FILE"
fi

echo ""
echo "Zed configuration updated."
echo ""
echo "Next steps:"
echo "  1. Restart Zed if it is running"
echo "  2. Press Ctrl+Enter (or Cmd+Enter on Mac) to open Assistant"
echo "  3. Try asking: 'What is Python?'"
echo ""
echo "Keyboard shortcuts:"
echo "  Ctrl+Enter / Cmd+Enter — Open Assistant"
echo "  Ctrl+Shift+A           — Insert AI suggestion"
echo ""
echo "Docs: docs/remote-ide-setup.md"
