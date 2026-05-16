# Operations Runbook: Backup, Restore, and Incident Response

This guide provides operational procedures for devbox maintenance, disaster recovery, and common troubleshooting scenarios.

## Backup and Snapshot Mechanism

Two distinct mechanisms share the directory `~/.local/share/devbox/backups/`:

1. **Per-file snapshots** — `setup.sh` calls `snapshot_file()` before any destructive
   operation (sudoers edit, ssh-config rewrite, config.env regeneration, .zshrc rewrite).
   Each snapshot is a single file copy under a timestamped directory.
2. **Volume + config archives** — `~/docker/backup.sh` (and the `devbox-backup.timer`
   systemd unit if installed) tar named Docker volumes via `docker run -v <vol>
   alpine@sha256:... tar`, plus per-service `.env` files, `.secrets/`, and
   `acme.json` (HTTPS mode). Output is a single `.tar.gz` archive, optionally
   GPG- or age-encrypted.

### Listing snapshots and archives

```bash
ls -lah ~/.local/share/devbox/backups/

# Per-file snapshots:
#   20260516T084230Z/sshd_config           (single file copy)
#   20260516T084315Z/config.env            (single file copy)
#   20260516T091000Z/dashboard-auth.yml    (single file copy)
#
# Volume + config archives:
#   devbox-backup-20260516T030000Z.tar.gz.gpg
#   devbox-backup-20260517T030000Z.tar.gz.age
```

### Manual snapshot before risky changes

```bash
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$HOME/.local/share/devbox/backups/${TS}-manual"
install -d -m 0700 "$BACKUP_DIR"
cp -a ~/docker            "$BACKUP_DIR/docker"
cp -a ~/.config/devbox    "$BACKUP_DIR/config"
echo "Manual snapshot: $BACKUP_DIR"
```

### Manual archive (named volumes + .env + acme)

```bash
~/docker/backup.sh
```

The archive lands at `~/.local/share/devbox/backups/devbox-backup-<ts>.tar.gz` (encrypted to `.gpg` or `.age` if a key is available).

### Disk space cleanup

Snapshots and archives accumulate. Prune anything older than 30 days:

```bash
# Per-file snapshots (timestamped dirs)
find ~/.local/share/devbox/backups -maxdepth 1 -type d -name '20*' -mtime +30 -print -exec rm -r {} \;

# Volume archives
find ~/.local/share/devbox/backups -maxdepth 1 -type f -name 'devbox-backup-*' -mtime +30 -print -delete
```

## Restore

### From a per-file snapshot

```bash
ls ~/.local/share/devbox/backups/
# pick a timestamped dir, e.g. 20260516T084315Z
SNAPSHOT=20260516T084315Z

# See what was snapshotted
ls ~/.local/share/devbox/backups/$SNAPSHOT/

# Compare to current
diff -u ~/.local/share/devbox/backups/$SNAPSHOT/dashboard-auth.yml \
        ~/docker/traefik/dynamic/dashboard-auth.yml

# Restore
cp -a ~/.local/share/devbox/backups/$SNAPSHOT/dashboard-auth.yml \
      ~/docker/traefik/dynamic/dashboard-auth.yml
docker compose -f ~/docker/traefik/docker-compose.yml \
               -f ~/docker/traefik/docker-compose.lock.yml restart traefik
```

### From a manual snapshot directory

```bash
SNAPSHOT=20260516T091000Z-manual

# Full restore of ~/docker
cp -a ~/.local/share/devbox/backups/$SNAPSHOT/docker/. ~/docker/

# Or restore the config directory only
cp -a ~/.local/share/devbox/backups/$SNAPSHOT/config/. ~/.config/devbox/
```

### From a backup.sh archive

```bash
ARCHIVE=~/.local/share/devbox/backups/devbox-backup-20260516T030000Z.tar.gz.gpg

# Decrypt + extract to a staging dir
mkdir -p /tmp/devbox-restore
gpg --decrypt "$ARCHIVE" | tar -xz -C /tmp/devbox-restore

# Inspect contents
ls /tmp/devbox-restore/

# Per-volume restore: pipe the .tgz back into a fresh volume
for vol in ollama-data openwebui-data; do
  docker volume create "$vol"
  docker run --rm -v "$vol":/data \
    -v /tmp/devbox-restore:/backup alpine \
    sh -c "cd /data && tar -xzf /backup/$vol.tgz"
done
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

## Automated Backups

DevBox ships `~/docker/backup.sh` as part of `scripts/host/`. It exports named
Docker volumes via `docker run -v <vol> ${ALPINE_BACKUP_IMAGE} tar`, captures
per-service `.env` files, `~/docker/.secrets/`, and the HTTPS-mode
`acme.json`, then writes a single archive under
`~/.local/share/devbox/backups/`. The archive is encrypted to GPG (if a key
is present) or age (if a key is configured), or left plaintext with a loud
warning.

### Daily systemd timer (recommended)

`make install-systemd` installs `devbox.service` + `devbox-backup.timer`. The
timer runs `backup.sh` daily with `Persistent=true` (catches up after host
reboot) and a randomized delay up to 30 minutes.

```bash
sudo make install-systemd
sudo systemctl list-timers devbox-backup.timer
```

### Cron alternative

If you prefer cron:

```bash
crontab -e
# Add (daily at 03:00, jittered ±10 min):
17 3 * * * sleep $((RANDOM % 600)); ~/docker/backup.sh >> ~/.local/share/devbox/backups/backup.log 2>&1
```

### Manual run

```bash
~/docker/backup.sh
# Output: ~/.local/share/devbox/backups/devbox-backup-<ts>.tar.gz[.gpg|.age]
```

See the [Restore](#restore) section above for the per-volume restore recipe.

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
# NAMES                STATUS
# traefik              Up (healthy)
# ollama               Up (healthy)
# openwebui            Up (healthy)
# docker-socket-proxy  Up (healthy)
```

## References

- **ARCHITECTURE.md:** Snapshot and restore architecture
- **ARCHITECTURE.md:** Services extraction (explains what ~/docker/ contains)
- **docs/security.md:** Security incident response
- **docs/updating.md:** Image digest updates and troubleshooting
