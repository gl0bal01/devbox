# Laptop Configuration Scripts

Scripts to configure your local laptop to connect to a remote DevBox server running Ollama.

## Prerequisites

1. A running DevBox server with Ollama configured
2. Tailscale installed on both server and laptop
3. Server's Tailscale IP address (run `tailscale ip -4` on server)

## Available Scripts

| Script | Purpose |
|--------|---------|
| `ollama-setup.sh` | Add shell functions for quick AI queries |
| `zed-setup.sh` | Configure Zed editor for remote Ollama |
| `shell-config.txt` | Shell configuration snippet (copy-paste) |

## Usage

### Quick Shell Setup

```bash
# Set your server's Tailscale IP
export OLLAMA_SERVER_IP="100.x.x.x"

# Run the setup script
bash scripts/laptop/ollama-setup.sh
```

After running, you have these commands available:

```bash
ask "What is Python?"          # Quick answer
askcode "Write hello world"    # Code-focused answer
chat "Explain Docker"          # Streaming response
ollamals                       # List remote models
```

### Zed Editor Setup

```bash
export OLLAMA_SERVER_IP="100.x.x.x"
bash scripts/laptop/zed-setup.sh
```

This creates `~/.config/zed/settings.json` with Ollama configuration.

### Manual Setup

If you prefer manual configuration, copy the contents of `shell-config.txt` to your `~/.bashrc` or `~/.zshrc` and update the `OLLAMA_SERVER_IP` variable.

## Finding Your Server IP

```bash
# On your server
tailscale ip -4

# Or from your laptop via SSH
ssh your-server "tailscale ip -4"
```

## See Also

- [Remote IDE Setup](../../docs/remote-ide-setup.md) - Complete IDE configuration guide
- [Quick Reference](../../docs/quick-reference.md) - Command cheat sheet
