#!/bin/bash
# Ollama Remote Setup Script for Laptop
#
# This script configures your laptop to access a remote Ollama server
# via Tailscale. It adds shell functions for quick AI interactions.
#
# Location: scripts/laptop/ollama-setup.sh
#
# Usage:
#   export OLLAMA_SERVER_IP="100.x.x.x"  # Your server's Tailscale IP
#   bash scripts/laptop/ollama-setup.sh
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

OLLAMA_HOST="http://${OLLAMA_SERVER_IP}:11434"

# Detect shell configuration file
if [ -n "$ZSH_VERSION" ]; then
    SHELL_CONFIG="$HOME/.zshrc"
elif [ -n "$BASH_VERSION" ]; then
    SHELL_CONFIG="$HOME/.bashrc"
else
    SHELL_CONFIG="$HOME/.profile"
fi

echo "Setting up Ollama remote access..."
echo "Target: $OLLAMA_HOST"
echo "Shell config: $SHELL_CONFIG"
echo ""

# Backup existing config
cp "$SHELL_CONFIG" "$SHELL_CONFIG.backup.$(date +%Y%m%d_%H%M%S)"

# Add configuration
cat >> "$SHELL_CONFIG" << 'SHELLCONFIG'

# Remote Ollama Configuration
# Added by scripts/laptop/ollama-setup.sh
SHELLCONFIG

cat >> "$SHELL_CONFIG" << EOF
export OLLAMA_SERVER_IP="${OLLAMA_SERVER_IP}"
export OLLAMA_HOST="http://\${OLLAMA_SERVER_IP}:11434"
EOF

cat >> "$SHELL_CONFIG" << 'SHELLCONFIG'

# Quick ask - get just the answer
ask() {
    if [ -z "$1" ]; then
        echo "Usage: ask \"your question here\""
        return 1
    fi

    local prompt="$*"
    curl -s "$OLLAMA_HOST/api/generate" -d "{
        \"model\": \"qwen3\",
        \"prompt\": \"$prompt\",
        \"stream\": false
    }" | jq -r '.response'
}

# Code-specific questions
askcode() {
    if [ -z "$1" ]; then
        echo "Usage: askcode \"your code question\""
        return 1
    fi

    local prompt="You are a coding assistant. Answer concisely with code when appropriate. Question: $*"
    curl -s "$OLLAMA_HOST/api/generate" -d "{
        \"model\": \"qwen3\",
        \"prompt\": \"$prompt\",
        \"stream\": false
    }" | jq -r '.response'
}

# Chat with streaming (see responses in real-time)
chat() {
    if [ -z "$1" ]; then
        echo "Usage: chat \"your question\""
        return 1
    fi

    local prompt="$*"
    curl -s "$OLLAMA_HOST/api/generate" -d "{
        \"model\": \"qwen3\",
        \"prompt\": \"$prompt\",
        \"stream\": true
    }" | while IFS= read -r line; do
        echo "$line" | jq -r '.response // empty' | tr -d '\n'
    done
    echo ""
}

# List remote models
alias ollamals='curl -s $OLLAMA_HOST/api/tags | jq -r ".models[].name"'

# Short alias
alias ai='ask'
# End Remote Ollama Configuration

SHELLCONFIG

echo "Configuration added to $SHELL_CONFIG"
echo ""
echo "Reload your shell with:"
echo "  source $SHELL_CONFIG"
echo ""
echo "Available commands:"
echo "  ask \"question\"       - Quick question, get answer only"
echo "  askcode \"question\"   - Code-specific questions"
echo "  chat \"question\"      - Streaming responses"
echo "  ollamals             - List available models"
echo "  ai \"question\"        - Short alias for 'ask'"
echo ""
echo "Examples:"
echo "  ask \"What is Python?\""
echo "  askcode \"Write a hello world in Python\""
echo "  chat \"Explain Docker\""
