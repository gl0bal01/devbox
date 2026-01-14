# DevBox Quick Reference

A command reference for daily DevBox operations.

## SSH Access

```bash
# Standard connection
ssh -p 5522 dev@YOUR_SERVER_IP

# Via Tailscale (after MagicDNS enabled)
ssh dev@devbox
```

## Service Management

```bash
# Start all services
start-all

# Stop all services
stop-all

# Check status
status

# Manual control
cd ~/docker
docker compose -f traefik/docker-compose.yml up -d
docker compose -f ollama-openwebui/docker-compose.yml up -d
```

## Service URLs

Add to `/etc/hosts` on your laptop:

```
TAILSCALE_IP  ai.internal traefik.internal ollama.internal
```

Get your Tailscale IP: `tailscale ip -4`

| Service | URL | Notes |
|---------|-----|-------|
| Open WebUI | http://ai.internal | Chat with Ollama models |
| Traefik | http://traefik.internal | Dashboard (Basic Auth) |
| Ollama API | http://ollama.internal | Or localhost:11434 |

## Ollama Commands

```bash
# Pull models
docker exec -it ollama ollama pull llama3.2
docker exec -it ollama ollama pull codellama
docker exec -it ollama ollama pull mistral

# List models
docker exec -it ollama ollama list

# Run model
docker exec -it ollama ollama run llama3.2

# API test
curl http://localhost:11434/api/generate -d '{
  "model": "llama3.2",
  "prompt": "Hello!"
}'
```

## AI Dev Stack

```bash
# Interactive menu
./install-ai-dev-stack.sh

# After installation
claude login                     # Claude Code
goose configure                  # Goose
llm keys set openai              # LLM
fabric --setup                   # Fabric
export ANTHROPIC_API_KEY=...     # OpenCode
```

## Penetration Testing

```bash
# Connect to HTB VPN
htb-vpn ~/htb/starting-point.ovpn

# Check VPN status
htb-vpn status

# Start Exegol
exegol

# Or with custom name
./docker/exegol-htb.sh my-session

# Inside Exegol
nmap -sC -sV 10.10.10.x
gobuster dir -u http://target -w /wordlists/...
msfconsole

# Disconnect VPN
htb-vpn stop
```

## Tailscale Commands

```bash
tailscale status        # Check connection and peers
tailscale ip -4         # Show your Tailscale IP
sudo tailscale up       # Connect
sudo tailscale down     # Disconnect
tailscale ping devbox   # Test connectivity
```

## Docker Shortcuts

```bash
dps                      # List running containers (formatted)
dpsa                     # List all containers
dlog container-name      # Follow logs
dex container-name bash  # Exec into container
dc up -d                 # docker compose up -d
dc down                  # docker compose down
dc logs -f               # Follow compose logs
dprune                   # Clean up unused resources
lzd                      # lazydocker TUI
```

## Git Shortcuts

```bash
lg                       # lazygit TUI
gs                       # git status
gp                       # git pull
gP                       # git push
```

## Editor

```bash
vim                      # neovim (lazyvim)
vi                       # neovim (lazyvim)
```

## Directory Structure

```
~/
├── docker/
│   ├── traefik/              # Reverse proxy + socket proxy
│   ├── ollama-openwebui/     # AI stack
│   ├── exegol-workspace/     # Pentest workspace
│   ├── start-all.sh
│   ├── stop-all.sh
│   ├── status.sh
│   ├── security-check.sh
│   ├── exegol-htb.sh
│   └── htb-vpn.sh
├── projects/                 # Code projects
├── htb/                      # HTB OVPN files
└── install-ai-dev-stack.sh   # AI Dev Stack installer
```

## Security Notes

- SSH on port **5522** (not 22)
- Password auth **disabled** (key only)
- **No public ports** except SSH
- All services via **Tailscale only**
- UFW firewall **active**

## Common Tasks

```bash
# Restart all services
stop-all && start-all

# Update all containers
docker compose pull && docker compose up -d

# Check resource usage
docker stats

# Quick backup
tar -czvf ~/docker-backup-$(date +%Y%m%d).tar.gz ~/docker/

# Watch all logs
docker logs -f traefik & docker logs -f ollama & docker logs -f open-webui
```

---

*Last updated: 2026-01-13*
