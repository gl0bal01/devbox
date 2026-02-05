# Exegol Multi-Container Guide

Run multiple Exegol penetration testing containers simultaneously with browser-based remote desktop access.

## Command Reference

### exegol-htb.sh (Interactive Terminal)

```bash
exegol                                # Default: container "exegol-htb"
exegol my-box                         # Custom container name
exegol my-box --privileged            # Full host access (use if tools fail)
```

Opens an interactive terminal session. One terminal per container.

### exegol-remote.sh (Background with noVNC)

```bash
exegol-remote                                    # Default: exegol-htb on port 45377
exegol-remote my-box                             # Custom name, default port
exegol-remote my-box --port 45378                # Custom name and port
exegol-remote --port 45378                       # Default name, custom port
exegol-remote my-box --port 45378 --privileged   # All options
```

Starts Exegol in the background with VNC/noVNC. Access via browser at `http://exegol.internal:<PORT>/vnc.html`.

### exegol-vnc.sh (Add noVNC to Running Container)

```bash
exegol-vnc my-container              # Auto-detect VNC port, noVNC on 45377
exegol-vnc my-container 45378        # Specify noVNC web port
```

Useful for adding browser access to a container started with `exegol-htb.sh`.

## Running Multiple Containers

Exegol uses `--network host` so containers share the host network stack. This means each noVNC instance needs a **unique port**. The `--port` flag makes this easy.

### Why Multiple Containers?

- **Isolation**: Keep HTB exploitation separate from OSINT work
- **Persistence**: Each container keeps its own shell history and tool state
- **Parallel work**: Work on multiple boxes or tasks simultaneously
- **Clean separation**: Different tools/configs per engagement

### Port Allocation Convention

| Port  | Use Case | Command |
|-------|----------|---------|
| 45377 | HTB exploitation (default) | `exegol-remote` |
| 45378 | OSINT / reconnaissance | `exegol-remote osint --port 45378` |
| 45379 | Dev / tool testing | `exegol-remote dev --port 45379` |
| 45380+ | Additional containers | `exegol-remote box2 --port 45380` |

Ports 45377-45399 are recommended to keep them grouped and memorable.

## Use Cases

### HTB Exploitation (Default)

```bash
# Connect VPN and start default container
htb-vpn ~/htb/starting-point.ovpn
exegol-remote

# Access at http://exegol.internal:45377/vnc.html
# Attach a terminal alongside the desktop:
docker exec -it exegol-htb zsh
```

### OSINT Investigation

```bash
exegol-remote osint-work --port 45378

# Access at http://exegol.internal:45378/vnc.html
# Tools: maltego, spiderfoot, recon-ng, theHarvester
```

### Dev / Tool Testing

```bash
exegol-remote dev-test --port 45379

# Access at http://exegol.internal:45379/vnc.html
# Test new tools without affecting your main pentest env
```

### Multiple HTB Boxes Side-by-Side

```bash
exegol-remote htb-box1 --port 45377
exegol-remote htb-box2 --port 45378

# Two browser tabs, two separate environments
# Both share the host VPN (tun0)
```

## Common Workflows

### Start, Work, Stop

```bash
# Start
exegol-remote my-box --port 45378

# Work in browser at http://exegol.internal:45378/vnc.html

# Stop when done
docker stop my-box

# Remove container entirely
docker rm my-box
```

### Resume a Stopped Container

```bash
# Restart the container
docker start my-box

# Re-attach noVNC
exegol-vnc my-box 45378

# Access at http://exegol.internal:45378/vnc.html
```

### Attach Terminal to Running Container

```bash
# Open a shell in a running remote container
docker exec -it my-box zsh

# Run tools from the terminal while using the desktop
```

### List Running Exegol Containers

```bash
docker ps --filter "ancestor=ghcr.io/ThePorgs/Exegol-images:full" \
  --format "table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}"
```

## Troubleshooting

### noVNC Not Accessible

1. Check the container is running: `docker ps | grep exegol`
2. Verify the noVNC process: `docker exec my-box ps aux | grep websockify`
3. Re-run VNC setup: `exegol-vnc my-box 45378`
4. Check nothing else is using the port: `ss -tlnp | grep 45378`

### Port Already in Use

```
Error: Port 45378 is already in use
```

Another container or process is on that port. Either:
- Use a different port: `exegol-remote my-box --port 45380`
- Find what's using it: `ss -tlnp | grep 45378`
- Stop the conflicting container: `docker stop <name>`

### VPN Not Working in Container

- Exegol uses `--network host` and inherits the host's tun0 interface
- Check VPN on host: `htb-vpn status`
- Check routing: `ip route show dev tun0`
- All containers share the same VPN connection

### Container Won't Start

```bash
# Check Docker logs
docker logs my-box

# Common fix: remove stale container with same name
docker rm -f my-box
exegol-remote my-box --port 45378
```

### VNC Display Issues

```bash
# Kill and restart VNC inside the container
docker exec my-box bash -c "vncserver -kill :1" 2>/dev/null
docker exec my-box bash -c "vncserver -localhost yes -geometry 1920x1080 -SecurityTypes Plain -PAMService tigervnc :1"

# Then re-attach noVNC
exegol-vnc my-box 45378
```

---

*See also: [Quick Reference](quick-reference.md) for command cheat sheet*
