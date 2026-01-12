# DevBox

Automated provisioning script for secure remote development, pentesting, and AI workstations on Ubuntu 24.04 VPS instances.

## Overview

This script transforms a fresh Ubuntu 24.04 VPS into a fully configured development environment with:

- Zero-trust network access via Tailscale
- Internal service routing via Traefik
- Local AI inference with Ollama and Open WebUI
- Pentest toolkit with Exegol
- AI Coding Tools (Claude Code, OpenCode, Goose, LLM, Fabric)
- Remote development via SSH with tmux/neovim

The entire stack runs behind Tailscale with no public ports exposed (except SSH), making it suitable for sensitive development and security research.

### Security Hardened (v2.3)

All containers are configured with defense-in-depth security measures:

- **Secrets Management**: Stored in `.env` files with 600 permissions, credentials written to secure file (not terminal)
- **SSH Key Configuration**: Read from environment variable or file (no hardcoded keys)
- **Docker Socket Proxy**: Prevents container escape, INFO endpoint disabled
- **Container Security**: All containers run with `no-new-privileges`, `cap_drop: ALL`, and minimal capabilities
- **Traefik Security**: Dashboard protected with basicAuth, `api.insecure: false`, log rotation enabled
- **Resource Limits**: Memory, CPU, and PID limits on all containers
- **UFW Firewall**: Confirmation prompt before reset, preserves existing rules
- **SSH Hardening**: Key-only auth, uses modern `KbdInteractiveAuthentication` directive
- **VPN Security**: OVPN files auto-enforced to 600 permissions
- **Exegol Warnings**: Clear security warnings when running with disabled AppArmor/seccomp
- Health checks on all services

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
    |        (on-demand, specific capabilities - not privileged)              |
    |                                                                         |
    |   [AI Dev Stack] - Claude Code, OpenCode, Goose, LLM, Fabric            |
    |        (native CLI tools for AI-assisted development)                   |
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
DOMAIN="example.com"                    # Your domain (optional)
```

### SSH Public Key (REQUIRED)

The script reads your SSH public key from one of these sources (in order):

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

## What Gets Installed

| Component | Version | Purpose |
|-----------|---------|---------|
| User with sudo | - | Non-root user with passwordless sudo |
| SSH hardening | - | Non-standard port, key-only auth, root disabled |
| UFW firewall | - | Default deny, SSH only |
| Tailscale | Latest | Zero-trust mesh VPN |
| Docker | Pre-installed | Container runtime (verified, not installed) |
| Docker Socket Proxy | 0.3.0 | Secure Docker API access for Traefik |
| Traefik | Latest | Internal reverse proxy with label-based routing |
| Ollama | Latest | Local LLM inference server |
| Open WebUI | Latest | Chat interface for Ollama (requires CHOWN, DAC_OVERRIDE, FOWNER caps) |
| Claude Code | Latest | CLI tool for AI-assisted coding (installer provided) |
| OpenCode | Latest | Open-source multi-provider AI coding (installer provided) |
| Goose | Latest | Block's AI coding agent (installer provided) |
| LLM | Latest | Datasette CLI for LLMs (installer provided) |
| Fabric | Latest | AI prompts framework (installer provided) |
| mise | Latest | Polyglot version manager (node, python, go, etc.) |
| lazygit | Latest | Terminal UI for git |
| lazydocker | Latest | Terminal UI for Docker |
| lazyvim | Latest | Neovim distribution with IDE features |
| Oh-My-Zsh | Latest | Shell configuration with aliases |
| Exegol | full | Pentest container (pulled on first use) |

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

### 7. Verify Security Hardening

```bash
cd ~/docker
./security-check.sh
```

This validates all security measures are in place: socket proxy, secrets management, container security options, resource limits, and health checks.

## Usage

### Service Management

```bash
start-all       # Start all services
stop-all        # Stop all services
status          # Show service status and Tailscale info
security-check  # Verify security hardening is in place
```

### Accessing Services

| Service | URL | Auth |
|---------|-----|------|
| Open WebUI | http://ai.internal | App-level (create account) |
| Traefik Dashboard | http://traefik.internal | Basic Auth (admin/password in setup output) |
| Ollama API | http://ollama.internal or localhost:11434 | None |

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
├── .devbox-credentials               # Generated credentials (600 perms, DELETE after saving!)
├── docker/
│   ├── .gitignore                    # Prevents committing secrets
│   ├── traefik/
│   │   ├── docker-compose.yml        # Includes docker-socket-proxy
│   │   ├── traefik.yml
│   │   ├── logs/                     # Traefik logs with rotation
│   │   └── dynamic/
│   │       └── dashboard-auth.yml    # BasicAuth middleware (600 perms)
│   ├── ollama-openwebui/
│   │   ├── docker-compose.yml
│   │   ├── .env                      # Secrets (600 permissions)
│   │   └── .gitignore
│   ├── exegol-workspace/
│   ├── start-all.sh
│   ├── stop-all.sh
│   ├── status.sh
│   ├── security-check.sh             # Security verification script
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

### Container Security (v2.3 Hardening)

All containers are configured with defense-in-depth measures:

| Security Measure | Implementation |
|-----------------|----------------|
| **Secrets Management** | Stored in `.env` files with 600 permissions, credentials saved to secure file |
| **SSH Key Handling** | Keys read from env var or file, never hardcoded in script |
| **Docker Socket Protection** | Traefik uses `docker-socket-proxy` with INFO disabled |
| **Traefik API Security** | Dashboard protected with basicAuth, `insecure: false` |
| **Log Rotation** | Traefik logs with maxSize/maxBackups to prevent disk exhaustion |
| **Privilege Escalation Prevention** | All containers have `no-new-privileges:true` |
| **Capability Dropping** | All containers have `cap_drop: ALL` with minimal `cap_add` |
| **Resource Limits** | Memory, CPU, and PID limits on all containers |
| **UFW Safety** | Confirmation prompt before resetting existing rules |
| **Health Checks** | All services have health checks for monitoring |
| **VPN File Security** | OVPN files auto-enforced to 600 permissions |

### Authentication

| Service | Auth Method |
|---------|-------------|
| SSH | Key-based only (password disabled) |
| Root login | Disabled |
| Open WebUI | Application-level (disable signup after admin creation) |
| Traefik Dashboard | Basic Auth (credentials in setup output) |

### Open WebUI Security Note

Open WebUI requires specific Linux capabilities to write to its ChromaDB database:
- `CHOWN` - Change file ownership
- `DAC_OVERRIDE` - Bypass file permission checks
- `FOWNER` - Bypass permission checks on file operations

These capabilities are added back after `cap_drop: ALL` to allow proper database operations while maintaining security with `no-new-privileges:true`.

### Exegol Security

Exegol runs with specific capabilities instead of `--privileged` by default:
- `NET_ADMIN`, `NET_RAW` - Network tools (nmap, etc.)
- `SYS_PTRACE` - Debugging tools
- `--privileged` available as opt-in flag for edge cases

### Recommendations

1. **Save credentials securely** - Credentials are saved to `~/.devbox-credentials` - copy to password manager and delete
2. **Delete credentials file** - Run `rm ~/.devbox-credentials` after saving credentials
3. **Disable Open WebUI signup** - Edit `.env` and set `ENABLE_SIGNUP=false` after creating admin
4. **Run security checks** - Execute `./security-check.sh` periodically
5. **Enable MagicDNS** - In Tailscale admin console
6. **Configure Tailscale ACLs** - For multi-device access control
7. **Update images** - Pin to newer versions and rebuild:
   ```bash
   cd ~/docker/traefik && docker compose pull && docker compose up -d
   ```
8. **Monitor logs** - `docker logs -f traefik` or check `~/docker/traefik/logs/`
9. **Review audit report** - See `SECURITY-TODO.md` for remaining improvements

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

## Using Remote Ollama with Local IDE

You can use the remote Ollama instance with local IDEs like Zed or VS Code via SSH tunnel.

### Quick Setup

```bash
# Create SSH tunnel (run on your local machine)
ssh -L 11434:127.0.0.1:11434 dev@your-server -p 5522 -N

# Or run in background
ssh -L 11434:127.0.0.1:11434 dev@your-server -p 5522 -N -f
```

Then configure your IDE to use `http://localhost:11434` as the Ollama endpoint.

### Recommended Models for IDE Use

| Model | Best For | Notes |
|-------|----------|-------|
| **qwen3** | General coding, agentic tasks | Good tool support |
| **devstral** | Code completion | Mistral's coding model |
| **codellama** | Code completion | Stable, well-tested |
| **deepseek-coder-v2** | Code generation | Good performance |

For detailed configuration (Zed settings, persistent tunnels, troubleshooting), see **[REMOTE-IDE-OLLAMA-SETUP.md](REMOTE-IDE-OLLAMA-SETUP.md)**.

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

## Additional Documentation

- [REMOTE-IDE-OLLAMA-SETUP.md](REMOTE-IDE-OLLAMA-SETUP.md) - Using remote Ollama with local IDEs

## References

- [Hostinger VPS](https://hostinger.fr?REFERRALCODE=gl0bal01)
- [Tailscale Documentation](https://tailscale.com/kb/)
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Docker Socket Proxy](https://github.com/Tecnativa/docker-socket-proxy)
- [Ollama Documentation](https://ollama.ai/)
- [Claude Code Documentation](https://docs.anthropic.com/en/docs/claude-code)
- [OpenCode Documentation](https://github.com/opencode-ai/opencode)
- [Goose Documentation](https://block.github.io/goose/)
- [LLM Documentation](https://llm.datasette.io/)
- [Fabric Documentation](https://github.com/danielmiessler/fabric)
- [Exegol Documentation](https://exegol.readthedocs.io/)
- [LazyVim Documentation](https://www.lazyvim.org/)
- [lazygit Documentation](https://github.com/jesseduffield/lazygit)
- [lazydocker Documentation](https://github.com/jesseduffield/lazydocker)
- [mise Documentation](https://mise.jdx.dev/)

---

*Last updated: 2026-01-12 (v2.3 Security Hardened)*
