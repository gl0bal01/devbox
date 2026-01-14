# DevBox

Automated provisioning for secure remote development, penetration testing, and AI workstations on Ubuntu 24.04 VPS instances.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Post-Installation](#post-installation)
- [Usage](#usage)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Documentation](#documentation)
- [License](#license)

## Overview

DevBox transforms a fresh Ubuntu 24.04 VPS into a fully configured development environment. The entire stack runs behind Tailscale with no public ports exposed except SSH.

### Architecture

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
|   [Traefik :80] ----+---- [Open WebUI]      ai.internal                 |
|        |            |                                                   |
|        |            +---- [Ollama API]      ollama.internal             |
|        |            |                                                   |
|        |            +---- [Traefik Dashboard] traefik.internal (auth)   |
|        |                                                                |
|        +---> [Docker Socket Proxy] ---> /var/run/docker.sock            |
|              (internal network, read-only API access)                   |
|                                                                         |
|   [Exegol Container] <---> [HTB/THM VPN]                                |
|        (on-demand, specific capabilities)                               |
|                                                                         |
|   [AI Dev Stack] - Claude Code, OpenCode, Goose, LLM, Fabric            |
|        (native CLI tools for AI-assisted development)                   |
|                                                                         |
+-------------------------------------------------------------------------+
```

## Features

### Core Components

| Component | Description |
|-----------|-------------|
| Tailscale | Zero-trust mesh VPN for secure access |
| Traefik | Internal reverse proxy with label-based routing |
| Ollama | Local LLM inference server |
| Open WebUI | Chat interface for Ollama models |
| Exegol | Penetration testing container with full toolkit |

### AI Coding Tools

| Tool | Provider | Purpose |
|------|----------|---------|
| Claude Code | Anthropic | AI-assisted coding CLI |
| OpenCode | Open-source | Multi-provider AI coding |
| Goose | Block | AI coding agent |
| LLM | Datasette | CLI for language models |
| Fabric | danielmiessler | AI prompts framework |

### Development Tools

- **mise**: Polyglot version manager (Node, Python, Go)
- **lazygit**: Terminal UI for git
- **lazydocker**: Terminal UI for Docker
- **lazyvim**: Neovim distribution with IDE features
- **Oh-My-Zsh**: Shell configuration with aliases

### Security Hardening (v2.3)

- Secrets stored in `.env` files with 600 permissions
- Docker socket proxy prevents container escape
- All containers run with `no-new-privileges` and `cap_drop: ALL`
- Traefik dashboard protected with basic authentication
- Resource limits on all containers
- Health checks on all services

## Requirements

- Ubuntu 24.04 LTS
- Docker and Docker Compose pre-installed
- Minimum 4GB RAM (8GB or more recommended for Ollama)
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
NEW_USER="dev"                    # Username to create
USER_EMAIL="admin@example.com"    # Email for Let's Encrypt (future use)
SSH_PORT="5522"                   # SSH port (default: 5522)
DOMAIN="example.com"              # Your domain (optional)
```

### SSH Public Key (Required)

The script reads your SSH public key from these sources (in order):

1. **Environment variable**: `SSH_PUBLIC_KEY="ssh-ed25519 AAAA..."`
2. **File**: `~/.ssh/devbox_authorized_key` or `/root/.ssh/devbox_authorized_key`
3. **Manual**: Add key to `~/.ssh/authorized_keys` after setup

**Recommended approach**:

```bash
# Option 1: Set environment variable before running
export SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)"
./setup.sh

# Option 2: Create key file on server before running
echo "ssh-ed25519 AAAA..." > /root/.ssh/devbox_authorized_key
./setup.sh
```

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
TAILSCALE_IP  ai.internal traefik.internal ollama.internal
```

Replace `TAILSCALE_IP` with your server's Tailscale IP (`tailscale ip -4`).

### 5. Install AI Coding Tools

```bash
# Interactive menu
./install-ai-dev-stack.sh

# Or install directly
./install-ai-dev-stack.sh --all       # Install all tools
./install-ai-dev-stack.sh --claude    # Claude Code only
./install-ai-dev-stack.sh --status    # Check installation status
./install-ai-dev-stack.sh --update    # Update all installed tools
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

### 7. Verify Security

```bash
cd ~/docker
./security-check.sh
```

## Usage

### Service Management

```bash
start-all       # Start all services
stop-all        # Stop all services
status          # Show service status and Tailscale info
security-check  # Verify security hardening
```

### Accessing Services

| Service | URL | Authentication |
|---------|-----|----------------|
| Open WebUI | http://ai.internal | App-level (create account) |
| Traefik Dashboard | http://traefik.internal | Basic Auth |
| Ollama API | http://ollama.internal | None |

### Remote IDE Integration

Connect your local IDE to the remote Ollama instance. See [Remote IDE Setup](docs/remote-ide-setup.md) for detailed instructions.

**Quick setup with scripts**:

```bash
# Set your server's Tailscale IP
export OLLAMA_SERVER_IP="100.x.x.x"

# Configure shell functions for quick AI queries
bash scripts/laptop/ollama-setup.sh

# Configure Zed editor
bash scripts/laptop/zed-setup.sh
```

**Manual setup with SSH tunnel**:

```bash
# Create SSH tunnel (on your local machine)
ssh -L 11434:127.0.0.1:11434 dev@your-server -p 5522 -N

# Configure IDE to use http://localhost:11434
```

### Penetration Testing Workflow

```bash
# Connect to HTB VPN
htb-vpn ~/htb/lab.ovpn

# Check VPN status
htb-vpn status

# Launch Exegol with host network
exegol

# Disconnect VPN
htb-vpn stop
```

Inside Exegol, all tools (nmap, metasploit, gobuster) have direct access to the target network.

### Shell Aliases

**Docker**:
```bash
dps             # docker ps (formatted)
dpsa            # docker ps -a
dlog NAME       # docker logs -f NAME
dex NAME bash   # docker exec -it NAME bash
dc up -d        # docker compose up -d
dprune          # docker system prune -af
lzd             # lazydocker TUI
```

**Git**:
```bash
lg              # lazygit TUI
gs              # git status
gp              # git pull
gP              # git push
```

**Tailscale**:
```bash
tsip            # Show Tailscale IP
tsstatus        # Show Tailscale status
tsup            # Connect Tailscale
tsdown          # Disconnect Tailscale
```

## Security

### Network Exposure

- Only SSH (port 5522) is exposed to the public internet
- All other services are accessible only via Tailscale
- UFW firewall configured with default deny incoming

### Container Security

| Measure | Implementation |
|---------|----------------|
| Secrets Management | `.env` files with 600 permissions |
| Docker Socket Protection | Traefik uses docker-socket-proxy |
| Privilege Escalation Prevention | All containers have `no-new-privileges:true` |
| Capability Dropping | All containers have `cap_drop: ALL` |
| Resource Limits | Memory, CPU, and PID limits on all containers |

### Authentication

| Service | Method |
|---------|--------|
| SSH | Key-based only (password disabled) |
| Root login | Disabled |
| Open WebUI | Application-level (disable signup after admin creation) |
| Traefik Dashboard | Basic Auth |

### Recommendations

1. Save credentials from `~/.devbox-credentials` to a password manager, then delete the file
2. Disable Open WebUI signup after creating admin account
3. Run `./security-check.sh` periodically
4. Enable MagicDNS in Tailscale admin console
5. Configure Tailscale ACLs for multi-device access control

## Troubleshooting

### SSH Connection Refused

```bash
sudo systemctl status ssh      # Verify SSH is running
sudo ss -tlnp | grep ssh       # Check listening port
sudo ufw status                # Verify firewall
```

### Services Not Accessible

```bash
docker ps                      # Check containers are running
docker logs traefik            # Check Traefik logs
tailscale status               # Verify Tailscale connection
curl -H "Host: ai.internal" http://localhost  # Test internal routing
```

### Tailscale Authentication Failed

```bash
sudo tailscale logout
sudo tailscale up --accept-routes
```

For more troubleshooting scenarios, see [Troubleshooting Guide](docs/troubleshooting.md).

## Documentation

| Document | Description |
|----------|-------------|
| [Quick Reference](docs/quick-reference.md) | Command cheat sheet |
| [Ollama Optimization](docs/ollama-optimization.md) | Performance tuning for Ollama |
| [Remote IDE Setup](docs/remote-ide-setup.md) | Configure local IDE with remote Ollama |
| [Troubleshooting](docs/troubleshooting.md) | Common issues and solutions |
| [Laptop Scripts](scripts/laptop/README.md) | Configure laptop for remote Ollama |
| [Contributing](CONTRIBUTING.md) | How to contribute |

## Directory Structure

**Repository structure**:

```
devbox/
├── setup.sh                     # Main setup script (run on server)
├── docs/
│   ├── quick-reference.md       # Command cheat sheet
│   ├── ollama-optimization.md   # Ollama performance tuning
│   ├── remote-ide-setup.md      # IDE configuration guide
│   └── troubleshooting.md       # Common issues
├── scripts/
│   └── laptop/                  # Run on your laptop
│       ├── ollama-setup.sh      # Shell functions for AI queries
│       ├── zed-setup.sh         # Zed editor configuration
│       └── shell-config.txt     # Manual shell config snippet
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

**Server directory structure** (after running setup.sh):

```
~/
├── .devbox-credentials          # Generated credentials (DELETE after saving)
├── docker/
│   ├── traefik/                 # Reverse proxy configuration
│   ├── ollama-openwebui/        # AI stack configuration
│   ├── exegol-workspace/        # Pentest workspace
│   ├── start-all.sh
│   ├── stop-all.sh
│   ├── status.sh
│   └── security-check.sh
├── projects/                    # Your code projects
├── htb/                         # HTB OVPN files
└── install-ai-dev-stack.sh      # AI Dev Stack installer
```

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

- [Tailscale Documentation](https://tailscale.com/kb/)
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Ollama Documentation](https://ollama.ai/)
- [Claude Code Documentation](https://docs.anthropic.com/en/docs/claude-code)
- [Exegol Documentation](https://exegol.readthedocs.io/)
- [LazyVim Documentation](https://www.lazyvim.org/)

---

*Last updated: 2026-01-13 (v2.3 Security Hardened)*
