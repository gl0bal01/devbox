# DevBox Quick Reference Card

## SSH Access
```bash
# Standard (replace with your IP)
ssh -p 5522 dev@YOUR_SERVER_IP

# Via Tailscale (after MagicDNS enabled)
ssh dev@devbox
```

---

## Service Management

```bash
# Start all services
start-all

# Stop all services  
stop-all

# Check status
status

# Or manually
cd ~/docker
docker compose -f traefik/docker-compose.yml up -d
docker compose -f ollama-openwebui/docker-compose.yml up -d
```

---

## Access Services

### Setup /etc/hosts on your LAPTOP:
```bash
# Get your Tailscale IP
tailscale ip -4

# Add to /etc/hosts on your laptop:
100.x.x.x  ai.internal traefik.internal ollama.internal
```

### URLs:
| Service | URL | Notes |
|---------|-----|-------|
| Open WebUI | http://ai.internal | Chat with Ollama models |
| Traefik | http://traefik.internal | Dashboard (Basic Auth) |
| Ollama API | http://ollama.internal | Or localhost:11434 |

---

## Ollama

```bash
# Pull models
docker exec -it ollama ollama pull llama3.2
docker exec -it ollama ollama pull codellama
docker exec -it ollama ollama pull mistral
docker exec -it ollama ollama pull deepseek-coder

# List models
docker exec -it ollama ollama list

# Run model directly
docker exec -it ollama ollama run llama3.2

# API test
curl http://localhost:11434/api/generate -d '{
  "model": "llama3.2",
  "prompt": "Hello!"
}'
```

---

## Ai Dev Stack

```bash
# Interactive menu
./install-ai-dev-stack.sh
```

After installation:
```bash
claude login                     # Authenticate Claude Code
goose configure                  # Configure Goose
llm keys set openai              # Set OpenAI key for LLM
fabric --setup                   # Configure Fabric
export ANTHROPIC_API_KEY=...     # Set key for OpenCode
```

---

## HTB / Pentest Workflow

```bash
# 1. Connect to HTB VPN
htb-vpn ~/htb/starting-point.ovpn

# Check VPN status
htb-vpn status

# 2. Start Exegol
exegol

# Or with custom name
./docker/exegol-htb.sh my-session

# 3. Inside Exegol - you have full HTB access
nmap -sC -sV 10.10.10.x
gobuster dir -u http://target -w /wordlists/...
msfconsole

# 4. Disconnect VPN when done
htb-vpn stop
```

---

## Tailscale Commands

```bash
tailscale status        # Check connection & peers
tailscale ip -4         # Show your Tailscale IP
sudo tailscale up       # Connect
sudo tailscale down     # Disconnect
tailscale ping devbox   # Test connectivity
```

---

## Docker Shortcuts

```bash
dps                      # List running containers (formatted)
dpsa                     # List ALL containers
dlog container-name      # Follow logs
dex container-name bash  # Exec into container
dc up -d                 # docker compose up -d
dc down                  # docker compose down
dc logs -f               # Follow compose logs
dprune                   # Clean up unused resources
lzd                      # lazydocker TUI
```

---

## Lazy Tools

```bash
# lazygit - Terminal UI for git
lg                       # or: lazygit

# lazydocker - Terminal UI for Docker
lzd                      # or: lazydocker

# lazyvim - Neovim IDE
vim                      # or: nvim
```

---

## Directory Structure

```
~/
├── docker/
│   ├── traefik/              # Reverse proxy + socket proxy
│   │   ├── docker-compose.yml
│   │   ├── traefik.yml
│   │   └── dynamic/
│   ├── ollama-openwebui/     # AI stack (Ollama + Open WebUI)
│   │   ├── docker-compose.yml
│   │   └── .env
│   ├── exegol-workspace/     # Pentest workspace
│   ├── start-all.sh
│   ├── stop-all.sh
│   ├── status.sh
│   ├── security-check.sh
│   ├── exegol-htb.sh
│   └── htb-vpn.sh
├── projects/                 # Your code projects
├── htb/                      # HTB OVPN files
└── install-ai-dev-stack.sh   # AI Dev Stack installer
```

---

## Security Notes

- SSH on port **5522** (not 22)
- Password auth **disabled** (key only)
- **No public ports** except SSH
- All services via **Tailscale only**
- UFW firewall **active**

---

## Troubleshooting

```bash
# Services not starting?
docker ps -a                      # Check container status
docker logs traefik               # Check logs

# Can't connect via Tailscale?
tailscale status                  # Check if connected
sudo systemctl status tailscaled  # Check daemon

# Firewall issues?
sudo ufw status                   # Check rules

# SSH not working?
sudo sshd -t                      # Test config
sudo systemctl status sshd        # Check service
journalctl -u sshd -f            # SSH logs

# DNS not resolving?
cat /etc/hosts                    # Check local hosts
ping ai.internal                  # Test resolution
```

---

## Useful One-Liners

```bash
# Restart all services
stop-all && start-all

# Update all containers
docker compose pull && docker compose up -d

# Check resource usage
docker stats

# Quick backup of docker configs
tar -czvf ~/docker-backup-$(date +%Y%m%d).tar.gz ~/docker/

# Watch logs from all containers
docker logs -f traefik & docker logs -f ollama & docker logs -f open-webui
```
