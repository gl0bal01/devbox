# Security Model and Threat Boundaries

This document explains what devbox protects against, what it doesn't, and where the actual security boundaries are.

## Trust Model

Devbox implements a **network-centric security model**, not local privilege separation.

**What IS a security boundary:**
- **Tailscale ACL:** Only authenticated Tailscale peers can reach the services (default deny)
- **SSH key authentication:** SSH password auth is disabled; only key-based login is allowed
- **UFW firewall:** Host-level firewall denies all inbound except SSH (on port 5522) and UFW-managed rules
- **Authenticated peers only:** Services are restricted to known Tailscale peers; public internet has zero access

**What is NOT a security boundary:**
- **Local privilege separation:** The `dev` user in the `docker` group has root-equivalent access (can bind-mount `/` as root)
- **Sudoers rules alone:** Restrictive sudoers rules are enforced but don't prevent docker-group privilege escalation
- **Container isolation:** Exegol and other containers run with relaxed security options (AppArmor disabled, minimal capabilities) intentionally for tool functionality; container escape may grant host access
- **Credential file encryption:** By default, `.devbox-credentials` is stored plaintext on disk; optional GPG/age encryption is available but not enforced

## Privilege Boundaries

### Docker Group Membership (Root-Equivalent)

The `dev` user is in the `docker` group, which grants **root-equivalent access** on the host. This is by design:

```bash
# From docker group membership, an attacker can:
docker run -it --rm -v /:/host ubuntu /bin/bash
# Now inside the container:
chroot /host /bin/bash
# You now have root access on the host
```

This is not a limitation of devbox; it's a fundamental Docker design. The docker socket provides unrestricted access to the Docker daemon, which allows binding the entire filesystem.

**Acceptance of this risk:**
- The security boundary is the **Tailscale ACL + SSH hardening**, not local privilege separation
- If the SSH key is compromised, the attacker has full root access
- If the Tailscale account is compromised, the attacker has full network access to all services
- Local privilege escalation (via docker, kernel exploit, etc.) is out of scope

### Sudoers Whitelist

Sudoers is configured with explicit NOPASSWD rules for necessary privileged commands:
```
dev ALL=(root) NOPASSWD: /usr/sbin/ufw, /usr/bin/tailscale, /usr/sbin/openvpn
dev ALL=(root) NOPASSWD: /bin/systemctl restart docker, /bin/systemctl reload ufw
dev ALL=(root) PASSWD: ALL
```

These rules enforce that certain commands (firewall, VPN, Tailscale) don't require entering a password repeatedly. They are **not** a security boundary but a convenience feature. The `dev` user's root-equivalent docker access supersedes any sudoers restrictions.

## Threat Model (In-Scope vs Out-of-Scope)

### In-Scope Threats (Mitigated)

**Tailscale network compromise:**
- Attacker gains access to a Tailscale account and joins the network
- **Mitigation:** Tailscale ACL restricts access to known peers by IP
- **Action required:** Monitor Tailscale dashboard for unexpected peers; revoke compromised devices immediately

**SSH key compromise (stolen, leaked):**
- Attacker obtains the SSH private key (e.g., from a laptop backup)
- **Mitigation:** SSH key-only auth; password bruteforce is impossible
- **Action required:** Revoke the key immediately (remove from `authorized_keys`), generate a new key, re-deploy

**Upstream image registry compromise:**
- Docker Hub, GitHub Container Registry, or Ollama upstream is compromised and returns malicious images
- **Mitigation:** ARCHITECTURE.md (digest pinning) ensures exact images are deployed; malicious image would need to match the pinned digest
- **Action required:** Weekly CI smoke test (ARCHITECTURE.md) detects obvious breakage; cosign signature verification (ARCHITECTURE.md) confirms build provenance

**Setup.sh download compromise:**
- Bun, Rustup, Tailscale, or other installer URLs are MITM'd or registry is compromised
- **Mitigation:** ARCHITECTURE.md (fetch_and_verify) pins SHA256 of installers; hash mismatch blocks installation
- **Action required:** Emergency `DEVBOX_ALLOW_UNVERIFIED=1` override documented in docs/ops.md

**Hand-edit clobbering (accidental data loss):**
- Operator edits `~/docker/traefik/traefik.yml` and re-runs `setup.sh`, losing the edits
- **Mitigation:** ARCHITECTURE.md (pre-rsync snapshots) backs up `~/docker/` before rsync
- **Action required:** Restore from `~/.local/share/devbox/backups/<timestamp>/` (documented in docs/ops.md)

### Out-of-Scope Threats (Not Mitigated)

**Physical access:**
- Attacker has physical access to the server
- **Why out-of-scope:** No security can protect against physical access (disk can be removed, BIOS can be reset)
- **Recommendation:** Server should be in a physically secure location (data center, locked cabinet)

**Kernel exploits / zero-days:**
- Attacker finds a CVE in the Linux kernel and exploits it to gain root
- **Why out-of-scope:** No application-level mitigation possible; requires kernel patches
- **Recommendation:** Keep the OS patched; subscribe to Ubuntu security mailing list

**Container escape:**
- Attacker runs code in a container (Exegol, Ollama, etc.) and exploits a Docker/containerd bug to reach the host
- **Why out-of-scope:** Container security is a shared responsibility of Docker, kernel, and application configuration
- **Partially mitigated:** Security options (`no-new-privileges`, `cap_drop: ALL`, selective `cap_add`) reduce attack surface; however, Exegol intentionally disables AppArmor for tool functionality
- **Recommendation:** Keep Docker and the kernel patched; don't run untrusted container images

**Exegol upstream compromise:**
- ThePorgs/Exegol project is compromised and releases a malicious image
- **Why out-of-scope:** Exegol is a pentesting container intentionally running arbitrary tools; any additional trust verification is minimal value
- **Accepted risk:** Documented in ARCHITECTURE.md; operator accepts that Exegol is untrusted-by-design
- **Recommendation:** Review Exegol releases periodically; pin a specific known-good digest if reproducibility is critical

**GitHub Actions compromise:**
- GitHub Actions infrastructure is compromised; malicious `weekly-rebuild.yml` is deployed
- **Why partially out-of-scope:** GitHub Actions is infrastructure you don't control
- **Partially mitigated:** SLSA provenance (ARCHITECTURE.md) attests the build environment; operator can verify against GitHub's public logs
- **Recommendation:** Review cosign signatures carefully; if suspicious, re-build and sign the release locally

**Supply-chain attack on CI dependencies:**
- A GitHub Actions action (e.g., `cosign-installer`, `slsa-github-generator`) is compromised
- **Why out-of-scope:** Actions are third-party code; no devbox-level mitigation possible
- **Partially mitigated:** All action versions are pinned (ARCHITECTURE.md); known-good versions are committed
- **Recommendation:** Audit action code before updating; monitor for security announcements

## Incident Response

### SSH Key Compromise

1. **Immediately revoke the compromised key:**
   ```bash
   # On the server, remove the old key
   ssh-keygen -f ~/.ssh/authorized_keys -R "$(cat ~/.ssh/authorized_keys)"
   # Or manually edit ~/.ssh/authorized_keys and remove the public key
   ```

2. **Generate a new SSH key (on your laptop):**
   ```bash
   ssh-keygen -t ed25519 -C "devbox@$(hostname)" -f ~/.ssh/devbox -N "passphrase"
   ```

3. **Deploy the new key:**
   ```bash
   # Temporarily enable password auth or use an alternate access method
   # Then update authorized_keys with the new public key
   ```

4. **Verify access works with the new key:**
   ```bash
   ssh -i ~/.ssh/devbox dev@devbox
   ```

5. **Disable the old key completely and destroy it:**
   ```bash
   shred -u ~/.ssh/devbox.old
   ```

### Tailscale Account Compromise

1. **From the Tailscale web console, revoke the device:**
   - Go to https://login.tailscale.com/admin/machines
   - Find the device and click "Delete"

2. **On the server, run Tailscale auth again:**
   ```bash
   sudo tailscale logout
   sudo tailscale up
   ```

3. **Verify the new device appears in the console and has the correct IP**

4. **Monitor the Tailscale network for unexpected new devices**

### Upstream Image Compromise Detection

If `docker compose up -d --wait` fails on a service, check:

```bash
# Review recent digest changes
git log --oneline services/ | head -10

# Compare current lockfile with what CI generated
docker compose -f services/traefik/docker-compose.yml -f services/traefik/docker-compose.lock.yml config | grep image

# Check if the service is obviously broken
docker compose logs traefik | tail -50

# If suspicious, revert the last commit
git revert HEAD
docker compose up -d
```

## Credential Management

### Plaintext Storage

By default, `.devbox-credentials` (NOPASSWD file for Ansible/helper tools) is stored plaintext in `~/.devbox-credentials`. This file contains:
- Nextcloud admin credentials
- Ollama API keys (if any)
- Redis password
- Other service credentials

**Risk:** If the disk is readable by another user or compromised, credentials are exposed.

**Mitigation:**
- File is readable only by `dev:dev` (0600 permissions)
- Umask is set to 077 when creating the file (ARCHITECTURE.md)
- If GPG keys are present, the file is encrypted to `~/.devbox-credentials.gpg` automatically

**Recommendation:**
- If credentials are sensitive, enable GPG encryption (`gpg --list-keys` must return at least one key)
- Rotate credentials regularly
- Do not share the server with untrusted users
- Use Tailscale SSH (if available) instead of long-lived SSH keys where possible

### OVH Credentials (HTTPS Mode)

If `ENABLE_HTTPS=true`, OVH API credentials are read from:
```
${XDG_CONFIG_HOME:-$HOME/.config}/devbox/ovh.env
```

This file must contain:
```
OVH_ENDPOINT="ovh-eu"
OVH_APP_KEY="..."
OVH_APP_SECRET="..."
OVH_CONSUMER_KEY="..."
```

**Risk:** Credentials are plaintext; if the file is readable, credentials are exposed.

**Mitigation:**
- File permissions are enforced to 0600 (readable only by owner)
- File is NOT tracked in git (added to `.gitignore`)
- File is NOT backed up by default (Scenario E in pre-mortem)

**Recommendation:**
- Restrict `/etc/sudoers.d/` so only `dev` can read it (already done)
- Encrypt the file locally using GPG or age if storing on a shared system
- Rotate OVH credentials periodically
- Use dedicated OVH accounts for this infrastructure (not personal accounts)

## Scenario E: Partial Install Leaks Credentials

From the pre-mortem: if `setup.sh` is interrupted (SIGINT) between credential file creation and `chmod 600`, the plaintext credentials file could be left world-readable.

**Mitigations:**
- `umask 077` at the top of setup.sh (default umask creates 0700 files)
- `install -m 0600 /dev/null ~/.devbox-credentials` (atomic permissions before any content)
- `trap 'shred -u "${CREDS_FILE}" 2>/dev/null || true' INT TERM` (cleanup on signal)

**Verification:**
```bash
# Check for world-readable credential files
find ~ -maxdepth 1 -name '.devbox-credentials*' -perm /044
# Should return nothing (empty)
```

## Security Hardening Checklist

Run this after every install to verify the security model is in place:

```bash
# 1. Verify SSH key-only auth
sudo sshd -T | grep -E "^passwordauthentication|^pubkeyauthentication"
# Should show: passwordauthentication no, pubkeyauthentication yes

# 2. Verify UFW is active and denies by default
sudo ufw status
# Should show: Status: active, Default: deny (incoming), allow (outgoing), disabled (routed)

# 3. Verify docker group membership
id dev
# Should show: groups=...,docker,...

# 4. Verify Tailscale is connected
tailscale status | grep -E "^[[:space:]]+.*online"

# 5. Verify .env file permissions
ls -la ~/docker/*/.env
# Should show: -rw------- (0600)

# 6. Verify sudoers whitelist
sudo -l
# Should show only ufw, tailscale, openvpn, systemctl commands allowed NOPASSWD

# 7. Verify no credential files are world-readable
find ~ -maxdepth 1 -name '*.devbox-credentials*' -perm /044 || echo "OK: no world-readable creds"

# 8. Verify Traefik middleware are wired at entryPoint level (ARCHITECTURE.md)
docker exec traefik cat /etc/traefik/traefik.yml | grep -A 5 "entryPoints:" | head -20
```

## Ollama API basic auth (ollama-auth@file)

The Traefik route for `http://ollama.internal` (and `https://ollama.${DOMAIN}` in HTTPS mode) is protected with HTTP basic auth via the `ollama-auth@file` middleware.

**Key properties:**

- The basic-auth credential is generated **per install** by `setup.sh`: a random 32-character password plus an APR1 hash.
- The hash lives in `${DEVBOX_HOME}/traefik/dynamic/ollama-auth.yml` (mode 0600, owned by `dev`).
- The plaintext credential lives in `${DEVBOX_HOME}/.secrets/ollama-auth.txt` (mode 0600) in the form `ollama:<password>`. The `.secrets/` directory itself is mode 0700.
- The route is bound to the Tailscale entrypoint only; there is no public 0.0.0.0 bind for Ollama.

**Open WebUI is NOT affected by rotation.** Open WebUI reaches the Ollama backend on the internal Compose network (`http://ollama:11434`, defined in `services/ollama-openwebui/docker-compose.yml`). That path does not traverse Traefik and does not present credentials. Only external Tailscale clients of `http://ollama.internal` use the basic-auth credential.

**Rotation:**

```bash
~/docker/rotate-ollama-auth.sh
# Writes a new random password to:
#   ~/docker/traefik/dynamic/ollama-auth.yml   (mode 0600, new hash)
#   ~/docker/.secrets/ollama-auth.txt          (mode 0600, new plaintext)
# Traefik file provider auto-reloads on file change. Open WebUI keeps working.
```

After rotation, any external client (IDE plugins, curl, scripts) must read the new credential from `~/docker/.secrets/ollama-auth.txt`.

## Further Reading

- **ARCHITECTURE.md:** Docker group privilege model (detailed explanation)
- **ARCHITECTURE.md:** Cosign keyless and supply-chain verification
- **ARCHITECTURE.md:** Verified downloads and SHA pinning
- **ARCHITECTURE.md:** Image digest pinning
- **docs/ops.md:** Incident response runbook and backup/restore procedures
- **CONTRIBUTING.md:** Contributing to devbox securely
