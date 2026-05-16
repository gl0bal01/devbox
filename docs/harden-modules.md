# Hardening modules

Opt-in operator scripts under `scripts/host/harden-*.sh`. Each module:

- **Idempotent.** Re-running is safe.
- **Dry-run by default.** No mutation without `--apply`.
- **Conditionally applied.** Skips cleanly when its prerequisite is absent.
- **OS-gated** to Debian/Ubuntu (Ubuntu 24.04 verified).

| Module | What it does | When NOT to run |
|---|---|---|
| `harden-dnat-scope.sh` | Replaces wide-open `0.0.0.0/0` Docker DNAT rules with CIDR-scoped rules (default Tailscale CGNAT `100.64.0.0/10`). | Docker not installed; no published ports; you use UFW exclusively. |
| `harden-fail2ban.sh` | Installs `traefik-auth` filter + `traefik-auth` and `recidive` jails when Traefik is publicly reachable. | Traefik bound to a Tailscale IP / loopback (wrong layer — see below). |
| `harden-backup-skeleton.sh` | Installs a generic age-encrypted, systemd-timed backup pipeline (per service tag). | No systemd; no `age` available; no plan for the encryption keypair. |

## Mixed topology (Tailscale-only + public)

These modules support hosts that mix the two:

- **Tailscale-only services** — compose `ports:` binds to `${TAILSCALE_IP}:PORT:PORT`. Reachable only via the tailnet.
- **Public services** — compose `ports:` binds to `PORT:PORT` (or `0.0.0.0:PORT:PORT`). Reachable from the internet.

`harden-dnat-scope.sh` accepts `--port` to scope its action to one
container port at a time. `harden-fail2ban.sh` strict-detects each
Traefik container's published HostIp and refuses to install jails on the
Tailscale-bound shape (use `--force` to override). You can run multiple
Traefik instances or one Traefik with mixed routers — the modules act per
target, not globally.

---

## `harden-dnat-scope.sh`

### What it solves

Docker creates DNAT rules in `nat/PREROUTING` (`DOCKER` chain) for every
published container port. The default rule sources from `0.0.0.0/0`. On
a host that exposes interfaces beyond loopback / Tailscale, anything
that can route to the docker bridge wins. Scoping the DNAT to a trusted
CIDR (the tailnet) prevents the leak.

### Usage

```bash
# Dry-run: list candidate rules + the scoped replacements
sudo scripts/host/harden-dnat-scope.sh

# Apply (writes iptables; persists if iptables-persistent is installed)
sudo scripts/host/harden-dnat-scope.sh --apply

# Restrict to one port + custom CIDR
sudo scripts/host/harden-dnat-scope.sh --port 8787 --cidr 100.64.0.0/10 --apply
```

### Caveats

1. **Docker rebuilds the `DOCKER` chain on container restart.** The
   scoped rule is wiped on the next `docker compose up` for the
   targeted service. This script is a runtime patch. The permanent fix
   is `userland-proxy=false` + binding the host port to the Tailscale IP
   in `compose ports:` — exactly what `services/traefik/docker-compose.yml`
   does in this repo. Use the script when you can't or don't want to
   redeploy.
2. **UFW conflicts.** UFW rewrites large parts of the iptables ruleset
   on reload. If you use UFW, prefer `ufw route allow ...` over raw
   iptables. The script warns; it does not auto-translate.
3. **DNAT-to-loopback** (`--to-destination 127.x.y.z:PORT`) requires
   `net.ipv4.conf.<bridge>.route_localnet=1`. The script warns when it
   sees one; it does not set the sysctl for you.
4. **IPv4 only.** v1 does not handle `ip6tables`.

---

## `harden-fail2ban.sh`

### What it solves

`traefik-auth`: bans IPs that hit too many `401`/`403`s on Traefik
routes. `recidive`: bans IPs banned by other jails repeatedly (meta-jail).

### Why fail2ban is the wrong layer for Tailscale-bound services

`fail2ban` is a per-source-IP rate limiter. It only helps when the
protected service is reachable from a real, attributable source IP.

When Traefik is bound to a Tailscale IP (e.g. `${TAILSCALE_IP}:80:80`,
which is the devbox default), the only network path is via Tailscale.
`fail2ban` would mechanically work on the tailnet IP, but the right
layer for tailnet adversarial isolation is Tailscale ACLs / grants —
not per-IP banning. A compromised tailnet member ban is a one-line
Tailscale policy change, not an iptables rule.

When Traefik is loopback-bound and exposed via `tailscale serve`, the
kernel sees the source as `127.0.0.1`. Banning loopback breaks the
service for everyone. fail2ban is outright wrong in that topology.

### Strict detection

The script refuses to install jails unless **all** of:

1. A container named `traefik` (overridable with `--container`) is running.
2. Its image starts with `traefik:` or `traefik/traefik:`.
3. At least one published port maps the host side to `0.0.0.0` (or `[::]`).

### Usage

```bash
# Dry-run: prints what /etc/fail2ban/jail.d/devbox.local + filter would contain
sudo scripts/host/harden-fail2ban.sh

# Apply (requires fail2ban already installed; will not auto apt-install)
sudo scripts/host/harden-fail2ban.sh --apply

# If Traefik does not bind-mount /var/log/traefik to the host:
sudo scripts/host/harden-fail2ban.sh --apply --log-path /var/log/traefik/access.log
```

### Caveats

1. **`fail2ban` is not auto-installed.** `apt install fail2ban`. The
   script declines to make that decision for you.
2. **Traefik `accessLog` must be enabled** with the default common
   format and the file readable from the host. Without logs the jail
   is inert.
3. **`traefik-auth` filter regex pinned to Traefik v3.x.** A v4 release
   is likely to change the access-log format. Re-verify the filter
   after a Traefik major bump.
4. **Override flag exists but use sparingly.** `--force` installs even
   when Traefik is bound to non-public IPs. Document why in your runbook
   if you do this.

---

## `harden-backup-skeleton.sh`

### What it solves

One flag invocation lays down a full per-service backup pipeline:

```
/usr/local/sbin/<tag>-backup                  # the runner (tar | age, retention, rclone)
/etc/systemd/system/<tag>-backup.service      # oneshot
/etc/systemd/system/<tag>-backup.timer        # daily 03:17 UTC ±10min, Persistent=true
/etc/<tag>-backup/                            # config dir
/etc/<tag>-backup/backup-offsite.env.example  # offsite REMOTE= template
/var/backups/<tag>/                           # output (mode 0700)
/var/log/<tag>-backup-offsite.log             # rclone errors only
```

Encryption recipient: `/root/.config/<tag>-backup/recipient.pub`. The
script does **not** generate the keypair — key management is the
operator's job.

### Tag-as-namespace

`--tag` validates `^[a-z][a-z0-9-]{1,30}$`. It is the namespace for the
runner name (`<tag>-backup`), unit names, config dir, output dir, log
file, and recipient path. Listing `/usr/local/sbin/` shows one entry per
service; `systemctl list-timers '*-backup.timer'` shows one entry per
service.

### Usage

```bash
# Dry-run preview (prints runner + service + timer to stdout)
sudo scripts/host/harden-backup-skeleton.sh \
  --tag myapp \
  --path /home/myapp \
  --path /etc/myapp \
  --path /var/lib/myapp

# Apply (idempotent — re-run is safe)
sudo scripts/host/harden-backup-skeleton.sh \
  --tag myapp \
  --path /home/myapp --path /etc/myapp --path /var/lib/myapp \
  --retention 14 \
  --apply
```

### Keypair recipe (operator step, after install)

```bash
sudo install -d -m 0700 /root/.config/myapp-backup
sudo age-keygen -o /root/.config/myapp-backup/identity.txt
sudo chmod 600 /root/.config/myapp-backup/identity.txt
sudo grep '^# public key:' /root/.config/myapp-backup/identity.txt \
  | awk '{print $4}' \
  | sudo tee /root/.config/myapp-backup/recipient.pub > /dev/null
sudo chmod 644 /root/.config/myapp-backup/recipient.pub
```

### Smoke-test + restore

```bash
# Smoke-test
sudo /usr/local/sbin/myapp-backup
sudo ls -lh /var/backups/myapp/

# Restore (manually — no --restore flag)
sudo age -d -i /root/.config/myapp-backup/identity.txt \
  < /var/backups/myapp/myapp-<stamp>.tar.age \
  | sudo tar -xzf - -C /
```

### Off-site push (optional)

Drop `/etc/<tag>-backup/backup-offsite.env` (mode `0600`, `root:root`):

```
REMOTE=r2-myapp:myapp-backups/myapp
export RCLONE_CONFIG=/etc/myapp-backup/rclone.conf
```

Recommended pattern:

- Dedicated bucket per service (clean blast radius).
- Dedicated, bucket-scoped API token (Object Read+Write only).
- Per-service `rclone.conf` at `/etc/<tag>-backup/rclone.conf`
  (`root:root 0600`). Do not reuse `~/.config/rclone/rclone.conf` —
  service compromise then leaks only the service's storage credentials.
- No double encryption. The `.tar.age` is already age-encrypted; raw
  S3-compatible remote is sufficient.

### Uninstall

```bash
sudo scripts/host/harden-backup-skeleton.sh --tag myapp --uninstall --apply
```

Removes runner + units. **Keeps** `/var/backups/<tag>/`,
`recipient.pub`, and `/etc/<tag>-backup/`. `rm -rf` is your call.

### Caveats

1. **Key management is the operator's job.** The script will not
   `age-keygen` for you, will not move identity.txt offsite, will not
   shred. Move the private key to a password manager + a second offsite
   copy (encrypted USB, paper) and `shred -u` the local one. Backups
   continue to encrypt against `recipient.pub`. After the local
   identity is shredded, host compromise yields ciphertext only.
2. **`rclone` only required when `REMOTE=` is set.** Local-only backups
   work without it.
3. **Restore is manual.** Test the round-trip before relying on the
   snapshot. A backup that has never been restored is theatre.
