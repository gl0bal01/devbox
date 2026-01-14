# Troubleshooting Guide

Solutions for common DevBox issues.

## Table of Contents

- [SSH Issues](#ssh-issues)
- [Service Issues](#service-issues)
- [Tailscale Issues](#tailscale-issues)
- [Ollama Issues](#ollama-issues)
- [Docker Issues](#docker-issues)
- [VPN Issues](#vpn-issues)
- [Performance Issues](#performance-issues)

## SSH Issues

### Connection Refused

**Symptoms**: `ssh: connect to host ... port 5522: Connection refused`

**Diagnosis**:

```bash
# On server (via console or recovery)
sudo systemctl status ssh
sudo ss -tlnp | grep ssh
```

**Solutions**:

1. Verify SSH is running:
   ```bash
   sudo systemctl start ssh
   sudo systemctl enable ssh
   ```

2. Check correct port:
   ```bash
   grep "^Port" /etc/ssh/sshd_config
   # Should show: Port 5522
   ```

3. Verify firewall:
   ```bash
   sudo ufw status
   sudo ufw allow 5522/tcp
   ```

### Permission Denied (publickey)

**Symptoms**: `Permission denied (publickey)`

**Solutions**:

1. Verify your key is in authorized_keys:
   ```bash
   cat ~/.ssh/authorized_keys
   ```

2. Check permissions:
   ```bash
   chmod 700 ~/.ssh
   chmod 600 ~/.ssh/authorized_keys
   ```

3. Verify correct key on client:
   ```bash
   ssh -i ~/.ssh/id_ed25519 -p 5522 dev@server
   ```

### Connection Timeout

**Symptoms**: Connection hangs, no response

**Solutions**:

1. Verify server IP is correct
2. Check if server is online (ping from another source)
3. Verify port 5522 is open in cloud provider firewall

## Service Issues

### Services Not Accessible

**Symptoms**: Cannot access ai.internal, traefik.internal, etc.

**Diagnosis**:

```bash
# Check containers are running
docker ps

# Check Traefik logs
docker logs traefik

# Test internal routing
curl -H "Host: ai.internal" http://localhost
```

**Solutions**:

1. Verify containers are running:
   ```bash
   cd ~/docker
   ./start-all.sh
   ```

2. Check Traefik configuration:
   ```bash
   docker logs traefik 2>&1 | grep -i error
   ```

3. Verify DNS entries on client:
   ```bash
   cat /etc/hosts | grep internal
   ```

### Container Won't Start

**Diagnosis**:

```bash
docker ps -a                    # Check status
docker logs container-name      # Check logs
docker inspect container-name   # Check configuration
```

**Common causes**:

1. Port conflict: Another service using the same port
2. Volume permissions: Check directory ownership
3. Network issues: Verify network exists
   ```bash
   docker network ls | grep proxy-net
   ```

### Open WebUI Not Loading

**Symptoms**: 502 Bad Gateway or blank page

**Solutions**:

1. Check Open WebUI container:
   ```bash
   docker logs open-webui
   ```

2. Verify Ollama is running:
   ```bash
   docker exec -it ollama ollama list
   ```

3. Restart services:
   ```bash
   cd ~/docker/ollama-openwebui
   docker compose down && docker compose up -d
   ```

## Tailscale Issues

### Authentication Failed

**Symptoms**: Cannot complete Tailscale authentication

**Solutions**:

```bash
sudo tailscale logout
sudo tailscale up --accept-routes
```

Open the provided URL in your browser to re-authenticate.

### Cannot Reach Other Devices

**Diagnosis**:

```bash
tailscale status         # Check connection
tailscale ping device    # Test connectivity
```

**Solutions**:

1. Verify both devices are online in Tailscale admin
2. Check ACLs in Tailscale admin console
3. Restart Tailscale:
   ```bash
   sudo systemctl restart tailscaled
   ```

### MagicDNS Not Working

**Symptoms**: Cannot resolve device names

**Solutions**:

1. Enable MagicDNS in Tailscale admin console
2. Verify DNS settings:
   ```bash
   tailscale status --json | jq '.DNS'
   ```

## Ollama Issues

### Models Not Loading

**Diagnosis**:

```bash
docker exec -it ollama ollama list
docker logs ollama
```

**Solutions**:

1. Pull model again:
   ```bash
   docker exec -it ollama ollama pull model-name
   ```

2. Check disk space:
   ```bash
   df -h /var/lib/docker
   ```

3. Restart Ollama:
   ```bash
   docker restart ollama
   ```

### Out of Memory

**Symptoms**: Model crashes or fails to load

**Solutions**:

1. Use smaller model:
   ```bash
   docker exec -it ollama ollama pull llama3.2:1b
   ```

2. Check memory usage:
   ```bash
   docker stats ollama
   ```

3. Increase container memory limit in docker-compose.yml

### Slow Responses

**Causes and solutions**:

1. **No GPU**: Check if GPU is detected
   ```bash
   docker logs ollama 2>&1 | grep -i gpu
   ```

2. **Large model**: Use smaller model or quantized version

3. **Insufficient RAM**: Close other applications, use smaller model

4. **Suboptimal configuration**: See [Ollama Optimization](ollama-optimization.md) for tuning

### Remote Access Not Working

**Diagnosis**:

```bash
# From server
curl http://localhost:11434/api/tags

# From laptop
curl http://TAILSCALE_IP:11434/api/tags
```

**Solutions**:

1. Verify Ollama is bound to Tailscale IP (not localhost)
2. Check docker-compose.yml ports configuration
3. See [Remote IDE Setup](remote-ide-setup.md) for complete configuration
4. See [Ollama Optimization](ollama-optimization.md) for port binding options

## Docker Issues

### Docker Daemon Not Running

**Symptoms**: `Cannot connect to the Docker daemon`

**Solutions**:

```bash
sudo systemctl start docker
sudo systemctl enable docker
```

### Permission Denied

**Symptoms**: `permission denied while trying to connect to the Docker daemon`

**Solutions**:

```bash
sudo usermod -aG docker $USER
# Log out and back in, or:
newgrp docker
```

### Disk Full

**Diagnosis**:

```bash
df -h
docker system df
```

**Solutions**:

```bash
# Remove unused resources
docker system prune -af

# Remove unused volumes
docker volume prune -f

# Remove old images
docker image prune -af
```

### Network Issues

**Symptoms**: Containers cannot communicate

**Solutions**:

1. Verify network exists:
   ```bash
   docker network ls | grep proxy-net
   ```

2. Recreate network if needed:
   ```bash
   docker network create proxy-net
   ```

3. Reconnect containers:
   ```bash
   cd ~/docker
   ./stop-all.sh && ./start-all.sh
   ```

## VPN Issues

### HTB VPN Not Connecting

**Diagnosis**:

```bash
htb-vpn status
tail -f /tmp/htb-vpn.log
```

**Solutions**:

1. Verify OVPN file is valid
2. Check file permissions:
   ```bash
   chmod 600 ~/htb/*.ovpn
   ```

3. Kill existing connection:
   ```bash
   htb-vpn stop
   htb-vpn ~/htb/lab.ovpn
   ```

### No Route to HTB Network

**Diagnosis**:

```bash
ip addr show tun0
ip route | grep tun0
```

**Solutions**:

1. Verify VPN is connected:
   ```bash
   htb-vpn status
   ```

2. Check routing:
   ```bash
   ip route get 10.10.10.1
   ```

### Exegol Cannot Reach Targets

**Solutions**:

1. Launch Exegol with host network:
   ```bash
   ./docker/exegol-htb.sh
   ```

2. Verify from inside Exegol:
   ```bash
   ip addr
   ping 10.10.10.x
   ```

## Performance Issues

### High CPU Usage

**Diagnosis**:

```bash
docker stats
htop
```

**Solutions**:

1. Identify heavy container:
   ```bash
   docker stats --no-stream
   ```

2. Restart problematic service:
   ```bash
   docker restart container-name
   ```

3. Check for runaway processes:
   ```bash
   docker exec container-name top
   ```

### High Memory Usage

**Diagnosis**:

```bash
free -h
docker stats
```

**Solutions**:

1. Use smaller Ollama models
2. Reduce container memory limits
3. Stop unused services:
   ```bash
   docker stop container-name
   ```

### Slow Disk I/O

**Diagnosis**:

```bash
iostat -x 1
df -h
```

**Solutions**:

1. Check disk usage and clean up
2. Move Docker data to faster storage
3. Use SSD for Ollama models

## Getting Help

If issues persist:

1. Check container logs:
   ```bash
   docker logs container-name 2>&1 | tail -100
   ```

2. Run security check:
   ```bash
   cd ~/docker
   ./security-check.sh
   ```

3. Collect system info:
   ```bash
   uname -a
   docker version
   tailscale version
   ```

---

*Last updated: 2026-01-13*
