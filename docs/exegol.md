# Exegol Multi-Container Guide

Run multiple Exegol penetration testing containers simultaneously with browser-based remote desktop access, using the official Exegol CLI.

## CLI Commands (Official `exegol`)

```bash
exegol info                           # List all containers and their status
exegol stop my-box                    # Stop a running container
exegol rm my-box                      # Remove a container entirely
```

## `exegol-start.sh` Wrapper

The wrapper script calls the official `exegol` CLI with sensible defaults and auto-sets the VNC password so you can connect without a password prompt.

```bash
exegol [name] [--port PORT] [--vpn FILE] [--log] [--privileged]
```

### Arguments

| Argument | Default | Description |
|---|---|---|
| `name` | `exegol-htb` | Container name (actual container is `exegol-<name>`) |
| `--port PORT` | `45377` | noVNC web port |
| `--vpn FILE` | — | OpenVPN config file to pass to the CLI |
| `--log` | — | Enable Exegol logging |
| `--privileged` | — | Run with full privileges (use if tools fail) |

### VNC Password

On first start, the wrapper background-sets `root:exegol` via `docker exec`. When the desktop is ready you'll see:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅ Desktop ready!
   URL:      http://exegol.internal:PORT/vnc.html
   User:     root  |  Password: exegol
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Resume Behaviour

If the container `exegol-<name>` already exists, the script calls `exegol start <name>` to resume it (the official CLI restarts it and re-attaches the desktop).

## Running Multiple Containers

Each container needs a **unique noVNC port**.

### Port Allocation Convention

| Port  | Use Case | Command |
|-------|----------|---------|
| 45377 | HTB exploitation (default) | `exegol` |
| 45378 | OSINT / reconnaissance | `exegol osint --port 45378` |
| 45379 | Dev / tool testing | `exegol dev --port 45379` |
| 45380+ | Additional containers | `exegol box2 --port 45380` |

### Why Multiple Containers?

- **Isolation**: Keep HTB exploitation separate from OSINT work
- **Persistence**: Each container keeps its own shell history and tool state
- **Parallel work**: Work on multiple boxes or tasks simultaneously
- **Clean separation**: Different tools/configs per engagement

## Use Cases

### HTB Exploitation (Default)

```bash
# Connect VPN and start default container
htb-vpn ~/htb/starting-point.ovpn
exegol

# Access at http://exegol.internal:45377/vnc.html  (root / exegol)
# Attach a terminal alongside the desktop:
docker exec -it exegol-exegol-htb zsh
```

### OSINT Investigation

```bash
exegol osint-work --port 45378

# Access at http://exegol.internal:45378/vnc.html
# Tools: maltego, spiderfoot, recon-ng, theHarvester
```

### Dev / Tool Testing

```bash
exegol dev-test --port 45379

# Access at http://exegol.internal:45379/vnc.html
```

### Multiple HTB Boxes Side-by-Side

```bash
exegol htb-box1 --port 45377
exegol htb-box2 --port 45378

# Two browser tabs, two separate environments
# Both share the host VPN (tun0)
```

## Common Workflows

### Start, Work, Stop

```bash
# Start (creates container + desktop)
exegol my-box --port 45378

# Work in browser at http://exegol.internal:45378/vnc.html

# Stop when done
exegol stop my-box

# Remove container entirely
exegol rm my-box
```

### Resume a Stopped Container

```bash
# Re-enter existing container (wrapper detects it exists)
exegol my-box --port 45378
```

### Attach Terminal to Running Container

```bash
# Open a shell in a running container
docker exec -it exegol-my-box zsh
```

### List All Containers

```bash
exegol-list    # alias for: exegol info
```

## Troubleshooting

### Desktop Not Accessible

1. Check the container is running: `exegol info`
2. Verify the container name: Exegol CLI names containers `exegol-<name>`
3. Check port availability: `ss -tlnp | grep 45377`
4. Try stopping and restarting: `exegol stop my-box && exegol my-box`

### VNC Password Prompt

The wrapper auto-sets `root:exegol` in a background job. If you see a password prompt, the background job may not have run yet (container took >60s to start). Set it manually:

```bash
docker exec exegol-my-box bash -c "echo 'root:exegol' | chpasswd"
```

### Port Already in Use

```
Error: Port 45378 is already in use
```

Use a different port or find what's using it:

```bash
ss -tlnp | grep 45378
exegol my-box --port 45380
```

### VPN Not Working in Container

- Exegol uses `--network host` and inherits the host's tun0 interface
- Check VPN on host: `htb-vpn status`
- Check routing: `ip route show dev tun0`
- All containers share the same VPN connection

### Container Won't Start

```bash
# Check for name conflicts
exegol info

# Remove stale container and retry
exegol rm my-box
exegol my-box --port 45378
```

---

*See also: [Quick Reference](quick-reference.md) for command cheat sheet*
