#!/bin/bash
# Zed Ollama Configuration Script for Laptop
#
# This script configures Zed editor to use a remote Ollama server
# via Tailscale.
#
# Location: scripts/laptop/zed-setup.sh
#
# Usage:
#   export OLLAMA_SERVER_IP="100.x.x.x"  # Your server's Tailscale IP
#   bash scripts/laptop/zed-setup.sh
#
# Find your Tailscale IP:
#   ssh your-server "tailscale ip -4"

set -e

if [ -z "$OLLAMA_SERVER_IP" ]; then
    echo "Error: OLLAMA_SERVER_IP not set"
    echo ""
    echo "Usage:"
    echo "  export OLLAMA_SERVER_IP=\"100.x.x.x\"  # Your server's Tailscale IP"
    echo "  bash $0"
    echo ""
    echo "Find your Tailscale IP:"
    echo "  ssh your-server \"tailscale ip -4\""
    exit 1
fi

echo "Setting up Zed for remote Ollama access..."
echo "Server IP: $OLLAMA_SERVER_IP"
echo ""

# Create config directory
mkdir -p ~/.config/zed

# Backup existing config
if [ -f ~/.config/zed/settings.json ]; then
    BACKUP_FILE=~/.config/zed/settings.json.backup.$(date +%Y%m%d_%H%M%S)
    cp ~/.config/zed/settings.json "$BACKUP_FILE"
    echo "Backed up existing config to: $BACKUP_FILE"
fi

# Create Zed config
cat > ~/.config/zed/settings.json << EOF
{
  "language_models": {
    "ollama": {
      "api_url": "http://${OLLAMA_SERVER_IP}:11434",
      "low_speed_timeout_in_seconds": 120
    }
  },
  "assistant": {
    "version": "2",
    "default_model": {
      "provider": "ollama",
      "model": "qwen3"
    }
  }
}
EOF

echo "Zed configuration created at: ~/.config/zed/settings.json"
echo ""
echo "Next steps:"
echo "1. Restart Zed if it is running"
echo "2. Press Ctrl+Enter (or Cmd+Enter on Mac) to open Assistant"
echo "3. Try asking: 'What is Python?'"
echo ""
echo "Keyboard shortcuts:"
echo "  Ctrl+Enter / Cmd+Enter - Open Assistant"
echo "  Ctrl+Shift+A - Insert AI suggestion"
echo ""
echo "For more information, see docs/remote-ide-setup.md"
