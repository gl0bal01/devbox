# Operations Runbook: Backup, Restore, and Incident Response

This guide provides operational procedures for devbox maintenance, disaster recovery, and common troubleshooting scenarios.

## Backup and Snapshot Mechanism

Devbox uses timestamped pre-modification snapshots for recovery. Before major operations (rsync, sudoers changes, template rendering), setup.sh creates a backup in `~/.local/share/devbox/backups/`.

### Understanding Snapshots

```bash
# List all snapshots
ls -lah ~/.local/share/devbox/backups/

# Output:
# drwxr-xr-x  2026-04-13 14:30  20260413-143022/
# drwxr-xr-x  2026-04-12 09:15  20260412-091500/

# Each snapshot contains:
ls -lah ~/.local/share/devbox/backups/20260413-143022/
# docker-pre-rsync/     # Backup of ~/docker before rsync
# config-pre-rsync/     # Backup of ~/.config/devbox before rsync
```

### Manual Backups

Create a backup before making risky changes:

```bash
# Create a manual snapshot
BACKUP_DIR="$HOME/.local/share/devbox/backups/$(date +%Y%m%d-%H%M%S)-manual"
mkdir -p "$BACKUP_DIR"

cp -a ~/docker "$BACKUP_DIR/docker-before-change"
cp -a ~/.config/devbox "$BACKUP_DIR/config-before-change"

echo "Snapshot created: $BACKUP_DIR"
```

### Disk Space Cleanup

Snapshots consume disk space (~100-500MB each, depending on data). Clean up old snapshots periodically:

```bash
# List snapshots older than 30 days
find ~/.local/share/devbox/backups -maxdepth 1 -type d -mtime +30

# Delete snapshots older than 30 days
find ~/.local/share/devbox/backups -maxdepth 1 -type d -mtime +30 -exec rm -r {} \;

# Or manually delete specific old snapshots
rm -r ~/.local/share/devbox/backups/20260313-*/
```

## Restore from Snapshot

### Full Directory Restore

Restore the entire `~/docker/` directory from a snapshot:

```bash
# List available snapshots
ls ~/.local/share/devbox/backups/

# Choose a snapshot (e.g., 20260413-143022)
SNAPSHOT="20260413-143022"

# Preview what changed
diff -ur ~/.local/share/devbox/backups/$SNAPSHOT/docker-pre-rsync/ ~/docker/ | head -100

# Restore (this will overwrite the current ~/docker)
cp -r ~/.local/share/devbox/backups/$SNAPSHOT/docker-pre-rsync/ ~/docker/

# Verify
ls ~/docker/
docker compose -f ~/docker/traefik/docker-compose.yml config -q
```

### Selective File Restore

Restore only specific files or directories:

```bash
SNAPSHOT="20260413-143022"

# Restore a single service's configuration
cp -r ~/.local/share/devbox/backups/$SNAPSHOT/docker-pre-rsync/traefik/ ~/docker/traefik/

# Restore a single file
cp ~/.local/share/devbox/backups/$SNAPSHOT/docker-pre-rsync/traefik/traefik.yml ~/docker/traefik/

# Restore just the .env file
cp ~/.local/share/devbox/backups/$SNAPSHOT/docker-pre-rsync/traefik/.env ~/docker/traefik/.env
```

### Restore Config (Tailscale, SSH keys, etc.)

```bash
SNAPSHOT="20260413-143022"

# Restore the devbox config directory
cp -r ~/.local/share/devbox/backups/$SNAPSHOT/config-pre-rsync/ ~/.config/devbox/
```

## Pre-Install Validation

### Dry-Run Mode

Preview every phase without touching the host. Does not require root:

```bash
./setup.sh --dry-run
```

The flag prints a structured summary for each phase (apt packages, rsync pairs,
render_env template destinations, config.env keys, and a per-service
`rsync --dry-run` diff showing files that would change), then exits 0.
No file under `${HOME}/docker`, `/etc`, `/root`, or `/var/lock` is modified.

### Post-Install Verification Checklist

After running setup.sh, verify the installation with this checklist:

```bash
# 1. Verify all services start and pass health checks.
#    Helpers source the compose chain from ~/.config/devbox/config.env,
#    which references the base compose file, the .https overlay in HTTPS
#    mode, and docker-compose.lock.yml when the lockfile is committed.
~/docker/start-all.sh

# 2. Check service status
~/docker/status.sh

# 3. Verify security checks pass
~/docker/security-check.sh
echo "Exit code: $?"  # Should be 0

# 4. Test live connectivity (from another Tailscale peer)
curl -I http://ai.internal
# Expected: HTTP/1.1 200 OK (with security headers)

# 5. Verify rate limiting is active (from another peer, burst requests)
for i in {1..150}; do curl -s http://ai.internal > /dev/null; done
# After ~100 requests, should see 429 (Too Many Requests)

# 6. Test Traefik healthcheck (from inside the container network)
docker exec traefik curl -s http://traefik:8080/ping
# Expected: OK

# 7. Verify sudoers configuration
sudo -l
# Expected: lists ufw, tailscale, openvpn, systemctl commands as NOPASSWD

# 8. Check that Tailscale is connected
tailscale status | grep -E "^[[:space:]]+.*online"
# Expected: at least one peer online

# 9. Check firewall rules (if exegol was started)
sudo ufw status verbose | grep exegol
# Expected: rules are scoped to tailscale0 interface
```

## Incident Response

### Scenario A: Digest Refresh Produces Broken Upstream

**What breaks:** You run `update-images.sh --apply && git commit && ./start-all.sh` and a newly resolved digest is broken. Traefik fails to start; reverse proxy is down.

**Detection:**
```bash
# status.sh shows traefik unhealthy
~/docker/status.sh

# Or, check directly
docker compose -f ~/docker/traefik/docker-compose.yml \
              -f ~/docker/traefik/docker-compose.lock.yml \
              ps traefik
# Status: Exited

# Review logs
docker logs traefik | tail -50
```

**Recovery:**
```bash
# Revert the last commit (which updated digests)
git revert HEAD

# Redeploy from the prior commit
./start-all.sh

# Verify services are back online
~/docker/status.sh

# Investigate the broken upstream version
git log --oneline services/ | head -3
# Find out which version failed, report to upstream project
```

**Prevention:**
- The weekly CI (ARCHITECTURE.md) runs a smoke test before cutting a `weekly-*` tag
- Avoid running `update-images.sh --apply` manually; wait for the weekly CI release instead

### Scenario B: Hand-Edited Files Clobbered by setup.sh Re-run

**What breaks:** You edit `~/docker/traefik/traefik.yml` to add `--log.level=DEBUG` for debugging. Re-run `./setup.sh` and the edit is silently overwritten.

**Detection:** Manual review; the edit is lost.

**Recovery:**
```bash
# List available snapshots
ls ~/.local/share/devbox/backups/

# Find the snapshot taken before the setup.sh run that clobbered your edit
# (Usually the most recent snapshot before the time you re-ran setup.sh)
SNAPSHOT="20260413-143022"

# Compare what you had vs what's there now
diff -u ~/.local/share/devbox/backups/$SNAPSHOT/docker-pre-rsync/traefik/traefik.yml \
         ~/docker/traefik/traefik.yml

# Restore the file (if you want your edit back)
cp ~/.local/share/devbox/backups/$SNAPSHOT/docker-pre-rsync/traefik/traefik.yml \
   ~/docker/traefik/traefik.yml

# Restart the service
docker compose -f ~/docker/traefik/docker-compose.yml \
              -f ~/docker/traefik/docker-compose.lock.yml \
              restart traefik
```

**Prevention:**
- **Never hand-edit `~/docker/`** — it's regenerated on every setup.sh run
- If you need to customize config, either:
  - Edit the source in the repo (`services/traefik/traefik.yml` for HTTP mode or `services/traefik/traefik.https.yml.template` for HTTPS mode) and re-run setup.sh, or
  - Edit the .env file instead (which is preserved by the `--exclude '.env'` rsync rule)

**Workaround (if you must hand-edit):**
```bash
# Create a manual backup before editing
BACKUP_DIR="$HOME/.local/share/devbox/backups/$(date +%Y%m%d-%H%M%S)-before-manual-edit"
mkdir -p "$BACKUP_DIR"
cp -a ~/docker "$BACKUP_DIR/docker-before-edit"

# Now make your edits
vim ~/docker/traefik/traefik.yml

# Document what you changed
echo "Added --log.level=DEBUG for debugging" >> "$BACKUP_DIR/NOTES.txt"

# When done, document the change elsewhere (e.g., ticket system)
# so that next time setup.sh runs, you remember to re-apply the change
```

### Scenario C: SHA Mismatch Blocks Install During DR Rebuild

**What breaks:** You're rebuilding the box from scratch (disaster recovery). The pinned SHA in `download-manifest.sh` is outdated; the upstream CDN cache expired and returns 404.

**Detection:**
```bash
./setup.sh
# Error: fetch_and_verify failed
# Expected SHA: abc123...
# Status: 404 Not Found
# URL: https://bun.sh/install
```

**Recovery (preferred path):**
```bash
# Update the manifest to current versions
./scripts/update-manifest.sh --apply

# Commit the changes
git add scripts/lib/download-manifest.sh
git commit -m "Update download manifest for DR rebuild"

# Retry setup.sh
./setup.sh
```

**Recovery (emergency override, NOT RECOMMENDED):**
```bash
# Use the emergency override (explicitly logs loudly)
DEVBOX_ALLOW_UNVERIFIED=1 ./setup.sh
# WARNING: Downloads are NOT verified. Trust only if you're certain about the sources.

# After install completes, immediately update the manifest:
./scripts/update-manifest.sh --apply
git add scripts/lib/download-manifest.sh
git commit -m "Update manifest after unverified install"
```

### Scenario D: Traefik Health Check Failing

**What breaks:** Traefik service is down; the reverse proxy can't route traffic.

**Detection:**
```bash
docker ps | grep traefik
# Container exited

docker logs traefik | tail -50
# Shows error messages
```

**Common causes:**
1. **Port conflict:** Another service is using port 80 or 443
2. **Configuration error:** traefik.yml or dynamic/* file has invalid syntax
3. **TLS/ACME error:** Certificate issuance failed
4. **Docker image broken:** Newly pulled image is bad

**Recovery:**
```bash
# Check what's listening on ports 80, 443, 8080
sudo lsof -i :80
sudo lsof -i :443
sudo lsof -i :8080
# Kill any conflicts or note what's there

# Validate Compose syntax
docker compose -f ~/docker/traefik/docker-compose.yml config -q
# Should exit 0

# Check Traefik config
docker exec traefik traefik version
docker exec traefik cat /etc/traefik/traefik.yml | head -20

# Restart the service
docker compose -f ~/docker/traefik/docker-compose.yml \
              -f ~/docker/traefik/docker-compose.lock.yml \
              restart traefik

# Watch logs
docker logs -f traefik

# If still failing, revert to a prior working commit
git log --oneline services/traefik | head -5
git checkout <commit> -- services/traefik/
./start-all.sh
```

### Scenario E: Ollama Out of Memory

**What breaks:** Ollama stops responding; `docker logs ollama` shows "out of memory" errors.

**Detection:**
```bash
curl http://localhost:11434/api/generate \
  -d '{"model":"llama3.2","prompt":"test","stream":false}' \
  -v
# Hangs or returns 500

docker stats ollama
# MEMORY showing near mem_limit
```

**Recovery:**
```bash
# Check current memory limit
docker inspect ollama | grep -A 5 '"Memory"'

# Edit docker-compose.yml to increase mem_limit
vim ~/docker/ollama-openwebui/docker-compose.yml
# Change: mem_limit: 4g
# To:     mem_limit: 8g

# Restart ollama
docker compose -f ~/docker/ollama-openwebui/docker-compose.yml \
              restart ollama

# Monitor
docker stats ollama
```

## Automated Backup Script

Create a cron job for automated backups:

```bash
# Create the backup script
cat > ~/docker/backup.sh <<'EOF'
#!/bin/bash
set -euo pipefail

BACKUP_DIR="$HOME/.local/share/devbox/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_PATH="$BACKUP_DIR/$TIMESTAMP-auto"

# Create backup
mkdir -p "$BACKUP_PATH"
cp -a ~/docker "$BACKUP_PATH/docker"
cp -a ~/.config/devbox "$BACKUP_PATH/config"

# Optional: encrypt with GPG if available
if gpg --list-keys 2>/dev/null | grep -q "pub\|uid"; then
  tar -czf "$BACKUP_PATH/backup.tar.gz" \
    -C "$BACKUP_PATH" docker config
  gpg --encrypt --recipient "$GPGUSER" "$BACKUP_PATH/backup.tar.gz"
  rm -f "$BACKUP_PATH/backup.tar.gz"
  rm -rf "$BACKUP_PATH/docker" "$BACKUP_PATH/config"
  echo "Encrypted backup: $BACKUP_PATH/backup.tar.gz.gpg"
else
  echo "Unencrypted backup: $BACKUP_PATH"
fi

# Clean up backups older than 30 days
find "$BACKUP_DIR" -maxdepth 1 -type d -mtime +30 -exec rm -r {} \;
EOF

chmod +x ~/docker/backup.sh

# Add to crontab (run daily at 3 AM)
crontab -e
# Add: 0 3 * * * ~/docker/backup.sh
```

## Monitoring and Alerting

### Health Check Script

```bash
# Run this periodically to verify system health
~/docker/security-check.sh

# Expected output:
# [PASS] Docker socket proxy running
# [PASS] No hardcoded secrets in environment
# [PASS] .env file permissions OK (600)
# [PASS] Container security options set
# [PASS] Resource limits configured
# [PASS] Image versions pinned (not :latest)
# [PASS] Traefik dashboard auth configured
# [PASS] Health checks present
# All checks passed.
```

### Manual Health Verification

```bash
# Every day or week, run:
~/docker/status.sh

# Expected output:
# Traefik: UP (healthy)
# Ollama: UP (healthy)
# OpenWebUI: UP (healthy)
# Docker socket proxy: UP (healthy)

# All services UP. Tailscale peers connected: 2
```

## References

- **ARCHITECTURE.md:** Snapshot and restore architecture
- **ARCHITECTURE.md:** Services extraction (explains what ~/docker/ contains)
- **docs/security.md:** Security incident response
- **docs/updating.md:** Image digest updates and troubleshooting
