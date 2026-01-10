# DevBox

Automated provisioning script for secure remote development, pentesting, and AI workstations on Ubuntu 24.04 VPS instances.

## Overview

This script transforms a fresh Ubuntu 24.04 VPS into a fully configured development environment with:

- Zero-trust network access via Tailscale
- Internal service routing via Traefik
- Local AI inference with Ollama and Open WebUI
- Browser-based IDE with code-server
- Pentest toolkit with Exegol
- AI Coding Tools

The entire stack runs behind Tailscale with no public ports exposed (except SSH), making it suitable for sensitive development and security research.

## Architecture

```
                                    [Internet]
                                         |
                                    [Firewall]
                                    Port 5522 only
                                         |
    +------------------------------------+------------------------------------+
    |                                   VPS                                   |
    |                                                                         |
    |   [Tailscale] <---> [Your Devices]                                      |
    |        |                                                                |
    |        v                                                                |
    |   [Traefik :80] ----+---- [code-server]     code.internal               |
    |     (internal)      |                                                   |
    |                     +---- [Open WebUI]      ai.internal                 |
    |                     |                                                   |
    |                     +---- [Ollama API]      ollama.internal             |
    |                     |                                                   |
    |                     +---- [Traefik Dashboard] traefik.internal          |
    |                                                                         |
    |   [Exegol Container] <---> [HTB/THM VPN]                                |
    |        (on-demand, host network)                                        |
    |                                                                         |
    +-------------------------------------------------------------------------+
```

## Requirements

- Ubuntu 24.04 LTS (tested on Hostinger KVM)
- Docker and Docker Compose pre-installed
- Minimum 4GB RAM (8GB+ recommended for Ollama)
- Root access for initial setup
- SSH public key for authentication

## Quick Start

```bash
# Clone the repository
git clone https://github.com/gl0bal01/devbox.git
cd devbox

# Edit configuration (lines 20-30)
nano setup.sh

# Run as root
chmod +x setup.sh
./setup.sh
```

## Configuration

Edit these variables in `setup.sh` before running:

```bash
NEW_USER="dev"                          # Username to create
USER_EMAIL="admin@example.com"          # Email for Let's Encrypt (future use)
SSH_PORT="5522"                         # SSH port (default: 5522)
SSH_PUBLIC_KEY="ssh-ed25519 AAAA..."    # Your public key
DOMAIN="example.com"                    # Your domain (optional)
```

## What Gets Installed

| Component | Purpose |
|-----------|---------|
| User with sudo | Non-root user with passwordless sudo |
| SSH hardening | Non-standard port, key-only auth, root disabled |
| UFW firewall | Default deny, SSH only |
| Tailscale | Zero-trust mesh VPN |
| Docker | Container runtime (verified, not installed) |
| Traefik v3.6 | Internal reverse proxy with label-based routing |
| Ollama | Local LLM inference server |
| Open WebUI | Chat interface for Ollama |
| code-server | VS Code in browser |
| Claude Code | CLI tool for AI-assisted coding (installer provided) |
| OpenCode | Open-source multi-provider AI coding (installer provided) |
| Goose | Block's AI coding agent (installer provided) |
| LLM | Datasette CLI for LLMs (installer provided) |
| Fabric | AI prompts framework (installer provided) |
| mise | Polyglot version manager (node, python, go, etc.) |
| lazygit | Terminal UI for git |
| lazydocker | Terminal UI for Docker |
| lazyvim | Neovim distribution with IDE features |
| Oh-My-Zsh | Shell configuration with aliases |
| Exegol | Pentest container (pulled on first use) |

## Post-Installation

### 1. Verify SSH Access

From a new terminal on your local machine:

```bash
ssh -p 5522 dev@YOUR_SERVER_IP
```

### 2. Authenticate Tailscale

```bash
sudo tailscale up --accept-routes
```

Open the provided URL in your browser to authenticate.

### 3. Start Services

```bash
cd ~/docker
./start-all.sh
```

### 4. Configure Local DNS

Add to `/etc/hosts` on your local machine:

```
TAILSCALE_IP  code.internal ai.internal traefik.internal ollama.internal
```

Replace `TAILSCALE_IP` with your server's Tailscale IP (`tailscale ip -4`).

### 5. Install AI Coding Tools (Optional)

```bash
# Interactive menu
./install-ai-dev-stack.sh

# Or install directly
./install-ai-dev-stack.sh --all           # Install all tools
./install-ai-dev-stack.sh --claude        # Claude Code only
./install-ai-dev-stack.sh --opencode      # OpenCode only
./install-ai-dev-stack.sh --goose         # Goose only
./install-ai-dev-stack.sh --llm           # LLM (Datasette) only
./install-ai-dev-stack.sh --fabric        # Fabric only
./install-ai-dev-stack.sh --status        # Check what's installed
./install-ai-dev-stack.sh --update        # Update all installed tools
```

After installation:
```bash
claude login                     # Authenticate Claude Code
goose configure                  # Configure Goose
llm keys set openai              # Set OpenAI key for LLM
fabric --setup                   # Configure Fabric
export ANTHROPIC_API_KEY=...     # Set key for OpenCode
```

### 6. Pull Ollama Models

```bash
docker exec -it ollama ollama pull llama3.2
docker exec -it ollama ollama pull codellama
```

## Usage

### Service Management

```bash
start-all       # Start all services
stop-all        # Stop all services
status          # Show service status and Tailscale info
```

### Accessing Services

| Service | URL |
|---------|-----|
| VS Code | http://code.internal |
| Open WebUI | http://ai.internal |
| Traefik Dashboard | http://traefik.internal |
| Ollama API | http://ollama.internal or localhost:11434 |

### HTB/Pentest Workflow

```bash
# Connect to HTB VPN
htb-vpn ~/htb/lab.ovpn

# Check VPN status
htb-vpn status

# Launch Exegol with host network (inherits VPN)
exegol

# Disconnect VPN
htb-vpn stop
```

Inside Exegol, all tools (nmap, metasploit, gobuster, etc.) have direct access to the HTB network.

### Docker Aliases

```bash
dps             # docker ps (formatted)
dpsa            # docker ps -a (formatted)
dlog NAME       # docker logs -f NAME
dex NAME bash   # docker exec -it NAME bash
dc up -d        # docker compose up -d
dc down         # docker compose down
dprune          # docker system prune -af
lzd             # lazydocker TUI
```

### Git Aliases

```bash
lg              # lazygit TUI
gs              # git status
gp              # git pull
gP              # git push
```

### Editor Aliases

```bash
vim             # neovim (lazyvim)
vi              # neovim (lazyvim)
```

### Tailscale Aliases

```bash
tsip            # Show Tailscale IP
tsstatus        # Show Tailscale status
tsup            # Connect Tailscale
tsdown          # Disconnect Tailscale
```

## Directory Structure

```
~/
├── docker/
│   ├── traefik/
│   │   ├── docker-compose.yml
│   │   ├── traefik.yml
│   │   └── dynamic/
│   ├── ollama-openwebui/
│   │   └── docker-compose.yml
│   ├── code-server/
│   │   └── docker-compose.yml
│   ├── exegol-workspace/
│   ├── start-all.sh
│   ├── stop-all.sh
│   ├── status.sh
│   ├── exegol-htb.sh
│   └── htb-vpn.sh
├── projects/
├── htb/
└── install-ai-dev-stack.sh
```

## Security Considerations

### Network Exposure

- Only SSH (port 5522) is exposed to the public internet
- All other services are accessible only via Tailscale
- UFW firewall configured with default deny incoming

### Authentication

- SSH: Key-based authentication only, password auth disabled
- Root login: Disabled
- code-server: Password protected (generated during setup)
- Open WebUI: Application-level auth

### Recommendations

1. Rotate the generated passwords stored in the setup output
2. Enable MagicDNS in Tailscale admin console
3. Configure Tailscale ACLs for multi-device access control
4. Regularly update containers: `docker compose pull && docker compose up -d`
5. Monitor logs: `docker logs -f traefik`

## Idempotency

The script is designed to be run multiple times safely:

- Existing users are preserved
- Existing Docker networks are reused
- SSH configuration changes prompt for confirmation
- Docker stack overwrites require explicit confirmation
- SSH keys are not duplicated

## Troubleshooting

### SSH Connection Refused

```bash
# Verify SSH is running
sudo systemctl status ssh

# Check listening port
sudo ss -tlnp | grep ssh

# Verify firewall
sudo ufw status
```

### Services Not Accessible

```bash
# Check containers are running
docker ps

# Check Traefik logs
docker logs traefik

# Verify Tailscale connection
tailscale status

# Test internal routing
curl -H "Host: ai.internal" http://localhost
```

### Tailscale Authentication Failed

```bash
# Re-authenticate
sudo tailscale logout
sudo tailscale up --accept-routes
```

### Exegol VPN Issues

```bash
# Verify HTB VPN is connected on host
ip addr show tun0

# Check VPN logs
tail -f /tmp/htb-vpn.log
```

## Customization

### Adding New Services

Create a new docker-compose.yml with Traefik labels:

```yaml
services:
  myservice:
    image: myimage:latest
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myservice.rule=Host(`myservice.internal`)"
      - "traefik.http.services.myservice.loadbalancer.server.port=8080"
    networks:
      - proxy-net

networks:
  proxy-net:
    external: true
```

### Exposing Services Publicly

For temporary public access, add Cloudflare Tunnel:

```yaml
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    command: tunnel --no-autoupdate run --token YOUR_TUNNEL_TOKEN
    restart: unless-stopped
```

Configure public hostnames in Cloudflare Zero Trust dashboard.

## Tested Environments

| Provider | Instance Type | Status |
|----------|--------------|--------|
| Hostinger | KVM 8 (32GB RAM, 8 vCPU) | Verified |
| Hetzner | CX31 | Compatible |
| DigitalOcean | Droplet | Compatible |
| AWS | EC2 t3.medium+ | Compatible |

## License

MIT License. See [LICENSE](LICENSE) for details.

## References
- [Hostinger VPS](https://hostinger.fr?REFERRALCODE=gl0bal01)
- [Tailscale Documentation](https://tailscale.com/kb/)
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Ollama Documentation](https://ollama.ai/)
- [Claude Code Documentation](https://docs.anthropic.com/en/docs/claude-code)
- [OpenCode Documentation](https://github.com/opencode-ai/opencode)
- [Goose Documentation](https://block.github.io/goose/)
- [LLM Documentation](https://llm.datasette.io/)
- [Fabric Documentation](https://github.com/danielmiessler/fabric)
- [Exegol Documentation](https://exegol.readthedocs.io/)
- [code-server Documentation](https://coder.com/docs/code-server/)
- [LazyVim Documentation](https://www.lazyvim.org/)
- [lazygit Documentation](https://github.com/jesseduffield/lazygit)
- [lazydocker Documentation](https://github.com/jesseduffield/lazydocker)
- [mise Documentation](https://mise.jdx.dev/)
