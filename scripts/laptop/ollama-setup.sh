#!/usr/bin/env bash
# DevBox v3 — Ollama Remote Client Setup for Laptop
#
# Configures a local laptop to call a remote Ollama server via Tailscale.
# Adds shell functions (ask, askcode, chat, ai, ollamals) for quick AI lookups.
#
# v3 changes from v2 (F6 / Critic Medium #18):
#   - JSON payloads built via `jq -n --arg` so unsanitized prompts can no longer
#     escape the JSON envelope (the v2 functions concatenated the prompt directly
#     into a JSON string, which is a classic injection).
#   - Idempotent shell-rc append: re-running this script does NOT duplicate
#     the configuration block in ~/.zshrc / ~/.bashrc.
#   - Safe shell detection: prefers $SHELL over $ZSH_VERSION/$BASH_VERSION which
#     are unreliable when bash is invoked via `bash script.sh` (BASH_VERSION
#     is set even if the user's login shell is zsh).
#   - `set -euo pipefail` for safety.
#
# Usage:
#   export OLLAMA_SERVER_IP="100.x.x.x"   # Your server's Tailscale IP
#   bash scripts/laptop/ollama-setup.sh
#
# Find your Tailscale IP:
#   ssh your-server "tailscale ip -4"

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

OLLAMA_HOST="http://${OLLAMA_SERVER_IP}:11434"

# Detect login shell (more reliable than $ZSH_VERSION / $BASH_VERSION when
# this script is invoked as `bash script.sh` from a zsh login shell).
LOGIN_SHELL_BASENAME=$(basename "${SHELL:-$BASH}")
case "${LOGIN_SHELL_BASENAME}" in
  zsh)  SHELL_CONFIG="$HOME/.zshrc" ;;
  bash) SHELL_CONFIG="$HOME/.bashrc" ;;
  *)    SHELL_CONFIG="$HOME/.profile" ;;
esac

echo "Setting up Ollama remote access..."
echo "  Target:        $OLLAMA_HOST"
echo "  Shell config:  $SHELL_CONFIG"
echo "  Login shell:   $LOGIN_SHELL_BASENAME"
echo ""

# Idempotency marker — re-running this script must not duplicate the block.
MARKER_BEGIN="# >>> devbox-ollama-remote (managed) >>>"
MARKER_END="# <<< devbox-ollama-remote (managed) <<<"

# Backup once per run
if [ -f "$SHELL_CONFIG" ]; then
  cp "$SHELL_CONFIG" "$SHELL_CONFIG.devbox-backup.$(date +%Y%m%d_%H%M%S)"
fi

# Strip any previous managed block (idempotent re-run)
if [ -f "$SHELL_CONFIG" ] && grep -qF "$MARKER_BEGIN" "$SHELL_CONFIG"; then
  echo "  Removing previous devbox-ollama-remote block..."
  # Use a temp file rather than in-place sed to avoid TOCTOU on $SHELL_CONFIG
  tmp="${SHELL_CONFIG}.devbox-tmp.$$"
  awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
    $0 == b {skip=1; next}
    $0 == e {skip=0; next}
    !skip {print}
  ' "$SHELL_CONFIG" >"$tmp"
  mv "$tmp" "$SHELL_CONFIG"
fi

# Append the managed block. The shell functions inside use `jq -n --arg` to
# build JSON safely — see F6 / Medium #18 in the production-readiness review.
{
  echo ""
  echo "$MARKER_BEGIN"
  echo "# Managed by scripts/laptop/ollama-setup.sh — re-run to refresh."
  echo "export OLLAMA_SERVER_IP=\"${OLLAMA_SERVER_IP}\""
  echo "export OLLAMA_HOST=\"http://\${OLLAMA_SERVER_IP}:11434\""
  cat <<'OLLAMAFNS'

# Quick ask — returns just the answer
ask() {
  if [ $# -eq 0 ]; then
    echo "Usage: ask \"your question here\""
    return 1
  fi
  local prompt="$*"
  local payload
  payload=$(jq -n --arg m "qwen3" --arg p "$prompt" \
    '{model:$m, prompt:$p, stream:false}')
  curl -s "$OLLAMA_HOST/api/generate" -d "$payload" | jq -r '.response'
}

# Code-specific questions
askcode() {
  if [ $# -eq 0 ]; then
    echo "Usage: askcode \"your code question\""
    return 1
  fi
  local prompt="You are a coding assistant. Answer concisely with code when appropriate. Question: $*"
  local payload
  payload=$(jq -n --arg m "qwen3" --arg p "$prompt" \
    '{model:$m, prompt:$p, stream:false}')
  curl -s "$OLLAMA_HOST/api/generate" -d "$payload" | jq -r '.response'
}

# Chat with streaming
chat() {
  if [ $# -eq 0 ]; then
    echo "Usage: chat \"your question\""
    return 1
  fi
  local prompt="$*"
  local payload
  payload=$(jq -n --arg m "qwen3" --arg p "$prompt" \
    '{model:$m, prompt:$p, stream:true}')
  curl -s "$OLLAMA_HOST/api/generate" -d "$payload" | while IFS= read -r line; do
    printf '%s' "$(printf '%s' "$line" | jq -r '.response // empty')"
  done
  echo ""
}

# List remote models
ollamals() {
  curl -s "$OLLAMA_HOST/api/tags" | jq -r '.models[].name'
}

# Short alias for ask
alias ai='ask'
OLLAMAFNS
  echo "$MARKER_END"
} >>"$SHELL_CONFIG"

echo "Configuration appended to $SHELL_CONFIG"
echo ""
echo "Reload your shell with:"
echo "  source $SHELL_CONFIG"
echo ""
echo "Available commands:"
echo "  ask \"question\"       — Quick question, get answer only"
echo "  askcode \"question\"   — Code-specific questions"
echo "  chat \"question\"      — Streaming responses"
echo "  ollamals              — List available models"
echo "  ai \"question\"        — Short alias for 'ask'"
echo ""
echo "Examples:"
echo "  ask 'What is Python?'"
echo "  ask 'He said \"hi\" then walked away.'   # quotes/escapes are SAFE now"
echo "  askcode 'Write hello world in Rust'"
echo "  chat 'Explain Docker'"
