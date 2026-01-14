# Remote IDE Setup

This guide explains how to connect your local IDE and CLI tools to an Ollama instance running on a remote DevBox server.

## Table of Contents

- [Overview](#overview)
- [Connection Methods](#connection-methods)
- [IDE Configuration](#ide-configuration)
- [CLI Configuration](#cli-configuration)
- [Shell Functions](#shell-functions)
- [Recommended Models](#recommended-models)
- [Troubleshooting](#troubleshooting)

## Overview

By default, Ollama runs on `127.0.0.1:11434` (localhost only) on the remote server. This guide covers two methods to access it from your local machine:

1. **SSH Port Forwarding**: Best for temporary connections and maximum security
2. **Tailscale Network Binding**: Best for always-on access and convenience

### Prerequisites

Before starting, you need your server's Tailscale IP:

```bash
# Run on your server
tailscale ip -4

# Or from your laptop via SSH
ssh your-server "tailscale ip -4"
```

Set the environment variable for all scripts:

```bash
export OLLAMA_SERVER_IP="100.x.x.x"  # Replace with your Tailscale IP
```

## Connection Methods

### Method 1: SSH Port Forwarding

**Best for**: Maximum security, temporary connections, testing.

**Setup**:

```bash
# Forward remote port 11434 to local port 11434
ssh -L 11434:127.0.0.1:11434 user@remote-server -p 5522 -N

# Run in background
ssh -L 11434:127.0.0.1:11434 user@remote-server -p 5522 -N -f

# Persistent tunnel (requires autossh)
autossh -M 0 -L 11434:127.0.0.1:11434 user@remote-server -p 5522 -N
```

**Client Configuration**:
- IDE endpoint: `http://localhost:11434`
- CLI: No configuration needed (uses localhost by default)

### Method 2: Tailscale Network Binding

**Best for**: Always-on access, convenience, multiple clients.

**Step 1: Configure Ollama Docker**

Edit `~/docker/ollama-openwebui/docker-compose.yml` on your server:

```yaml
services:
  ollama:
    environment:
      - OLLAMA_HOST=0.0.0.0:11434
    ports:
      - "100.x.x.x:11434:11434"  # Replace with your Tailscale IP
```

**Step 2: Restart Ollama**

```bash
cd ~/docker/ollama-openwebui
docker compose down ollama && docker compose up -d ollama
```

**Step 3: Verify Connection**

```bash
curl http://100.x.x.x:11434/api/tags
```

**Client Configuration**:
- IDE endpoint: `http://100.x.x.x:11434` (your Tailscale IP)
- CLI: `export OLLAMA_HOST=http://100.x.x.x:11434`

### Security Comparison

| Method | Security | Setup | Maintenance | Network Exposure |
|--------|----------|-------|-------------|------------------|
| SSH Tunnel | High | Simple | Active tunnel required | Localhost only |
| Tailscale (IP-bound) | High | Moderate | None | Tailscale network only |
| Bind to 0.0.0.0:11434 | **Unsafe** | Simple | None | **All interfaces** |

**Warning**: Never use `ports: - "11434:11434"` without an IP prefix. This exposes Ollama on all network interfaces, including public IPs.

## IDE Configuration

### Zed Editor

Edit `~/.config/zed/settings.json`:

**For SSH Tunnel**:

```json
{
  "language_models": {
    "ollama": {
      "api_url": "http://localhost:11434",
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
```

**For Tailscale**:

```json
{
  "language_models": {
    "ollama": {
      "api_url": "http://100.x.x.x:11434",
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
```

**Automated Setup Script**:

```bash
export OLLAMA_SERVER_IP="100.x.x.x"  # Your Tailscale IP
bash scripts/laptop/zed-setup.sh
```

**Keyboard Shortcuts**:

| Shortcut | Action |
|----------|--------|
| Ctrl+Enter / Cmd+Enter | Open Assistant panel |
| Ctrl+Shift+A | Insert AI suggestion |
| / in Assistant | Slash commands menu |
| Escape | Close Assistant |

### VS Code with Continue Extension

1. Install the Continue extension
2. Open Continue settings (Ctrl+Shift+P, "Continue: Open Settings")
3. Add Ollama as a provider:

```json
{
  "models": [
    {
      "title": "Remote Ollama",
      "provider": "ollama",
      "model": "qwen3",
      "apiBase": "http://100.x.x.x:11434"
    }
  ]
}
```

### Multiple Models Configuration

For IDEs that support multiple models:

```json
{
  "language_models": {
    "ollama": {
      "api_url": "http://100.x.x.x:11434",
      "low_speed_timeout_in_seconds": 120,
      "available_models": [
        {
          "name": "qwen3",
          "display_name": "Qwen3",
          "max_tokens": 8192,
          "supports_tools": true
        },
        {
          "name": "codellama",
          "display_name": "Code Llama",
          "max_tokens": 4096,
          "supports_tools": false
        }
      ]
    }
  }
}
```

## CLI Configuration

### Ollama CLI

**SSH Tunnel Method**:

```bash
# No configuration needed - CLI uses localhost:11434 by default
ollama list
ollama run qwen3
```

**Tailscale Method**:

```bash
# Set environment variable
export OLLAMA_HOST="http://100.x.x.x:11434"

# Make permanent (add to ~/.bashrc or ~/.zshrc)
echo 'export OLLAMA_SERVER_IP="100.x.x.x"' >> ~/.bashrc
echo 'export OLLAMA_HOST="http://${OLLAMA_SERVER_IP}:11434"' >> ~/.bashrc
source ~/.bashrc

# Use normally
ollama list
ollama run qwen3
```

### API Testing

```bash
# List available models
curl http://localhost:11434/api/tags | jq '.models[].name'

# Test generation
curl http://localhost:11434/api/generate -d '{
  "model": "qwen3",
  "prompt": "Hello, world!",
  "stream": false
}'
```

## Shell Functions

Add these functions to your `~/.bashrc` or `~/.zshrc` for quick AI access:

```bash
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

# Chat with streaming
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
```

**Automated Setup Script**:

```bash
export OLLAMA_SERVER_IP="100.x.x.x"
bash scripts/laptop/ollama-setup.sh
```

## Recommended Models

| Model | Size | Use Case | Tool Support |
|-------|------|----------|--------------|
| qwen3 | Varies | General coding, agentic tasks | Yes |
| devstral | Medium | Code completion | Yes |
| codellama | 7B-34B | Code generation | Limited |
| deepseek-coder-v2 | 16B-236B | Advanced coding | Yes |

**Note**: Local models have limitations compared to cloud models (Claude, GPT-4) for complex agentic tasks requiring multi-step operations and file manipulation.

## Troubleshooting

### Port Already in Use (SSH Tunnel)

**Diagnosis**:

```bash
sudo lsof -i :11434
```

**Solutions**:

1. Stop local Ollama: `sudo systemctl stop ollama`
2. Use different local port: `ssh -L 11435:127.0.0.1:11434 remote -N`
3. Kill existing tunnel: `pkill -f "11434:127.0.0.1:11434"`

### Connection Failures

**Check network connectivity**:

```bash
# Verify Tailscale
tailscale status
ping 100.x.x.x

# Test port accessibility
curl http://100.x.x.x:11434/api/tags
```

**Verify OLLAMA_HOST**:

```bash
echo $OLLAMA_HOST
# Should output: http://100.x.x.x:11434
```

**Check tunnel status**:

```bash
ps aux | grep "ssh.*11434"
```

### IDE Not Detecting Models

1. Verify API connection: `curl http://endpoint/api/tags`
2. Restart IDE completely
3. Check IDE logs for connection errors
4. Verify firewall settings

### Slow Performance

Local models require significant compute resources:

- Large models (30B+) are slow on CPU
- Verify GPU usage: `docker logs ollama 2>&1 | grep -i gpu`
- Consider smaller models for faster responses
- Increase timeout in IDE: `"low_speed_timeout_in_seconds": 120`

### Zed-Specific Issues

**"Failed to connect to language model"**:

1. Check Tailscale connection:
   ```bash
   curl http://100.x.x.x:11434/api/tags
   ```
2. Ensure Tailscale is running: `tailscale status`
3. Check Zed logs: Ctrl+Shift+P, type "zed: open log"

**Models not showing up**:

1. Restart Zed completely
2. Check Assistant Panel settings (open with Ctrl+Enter)
3. Manually refresh: `curl http://100.x.x.x:11434/api/tags`

## References

- [Zed LLM Providers](https://zed.dev/docs/ai/llm-providers)
- [Ollama Documentation](https://docs.ollama.com/)
- [Tailscale Documentation](https://tailscale.com/kb/)

---

*Last updated: 2026-01-13*
