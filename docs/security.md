# Security model

This page covers what DevBox protects, where the boundaries are, and how to check them. Design rationale lives in [ARCHITECTURE.md](../ARCHITECTURE.md). Recovery steps live in [ops.md](ops.md#incident-response).

## Boundaries

The boundary is the network edge. DevBox does not try to separate privileges locally.

| Layer | What it enforces |
|---|---|
| UFW | Incoming traffic is denied by default. Only the SSH port (default 5522, rule comment `devbox-ssh`) is open to the internet. |
| SSH | Key-only login. Root login, password and keyboard-interactive auth are off, and `MaxAuthTries` is 3. fail2ban watches the real SSH port. |
| Tailscale | Every web service listens only on the host's Tailscale IP. Your tailnet ACLs decide who can reach that IP. |
| Traefik | Every entrypoint adds security headers and an allowlist of Tailscale ranges (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) plus loopback. The Ollama API and the Traefik dashboard also require basic auth. |

These are not boundaries:

- **The `docker` group is root-equivalent.** Anyone who can run `docker` can mount `/` into a container. The operator user is in `docker` and `sudo` by design, so a stolen operator SSH key means root on the host.
- **The NOPASSWD sudoers entries** in `/etc/sudoers.d/90-<user>` (`ufw`, `tailscale`, `openvpn`, `sshd -T`, and `pkill -F /run/devbox/htb-vpn.pid openvpn`) are there so the helpers don't prompt for a password. They don't restrict anything. Every other sudo command still asks for the user's password.
- **Exegol containers** are pentest environments. They use host networking, and run privileged if you ask for it. Treat them as part of the host.

Multi-user hosts: any local account can reach the Docker bridge networks, so it can talk to Ollama directly at its container IP (bypassing the basic auth) and to Open WebUI before its admin exists. DevBox assumes a single-operator server; don't give other people shell accounts on it.

Out of scope: physical access, kernel or container-runtime escapes, a compromised Tailscale account, and a malicious upstream image release that a digest refresh then pins (review the monthly refresh PR before merging it). Keep the OS patched and check the tailnet's device list regularly.

## Network exposure

Docker-published ports bypass UFW, because Docker inserts its own iptables rules ahead of UFW's. DevBox handles this as follows:

- Only Traefik publishes ports, and only on `TAILSCALE_IP`: port 80, plus 443 in HTTPS mode. If `TAILSCALE_IP` is unset, the compose files refuse to start instead of falling back to `0.0.0.0`.
- Ollama, Open WebUI and docker-socket-proxy publish nothing. Open WebUI reaches Ollama directly on the `proxy-net` Docker network.
- `/etc/sysctl.d/60-devbox.conf` sets `net.ipv4.ip_nonlocal_bind=1`. At boot, Docker can then bind the Tailscale IP before `tailscale0` exists. Without it, Traefik would fail to start after a reboot.
- `security-check.sh` fails if any container publishes on `0.0.0.0` or `::`.

To expose a new service, route it through Traefik with a `Host(...)` label. Never add a `ports:` entry. Host processes that listen on all interfaces, such as Exegol's noVNC desktop, are filtered by UFW like any other host process.

If you install with `DEVBOX_ALLOW_NO_TAILSCALE=true`, services bind to `127.0.0.1`. You can then reach them only through SSH port forwarding.

## Hardening in place

- **SSH:** the drop-in is `/etc/ssh/sshd_config.d/00-devbox.conf`. The `00-` prefix matters: sshd keeps the first value it reads, and cloud images ship `50-cloud-init.conf` with `PasswordAuthentication yes`. setup.sh validates the drop-in with `sshd -t` and checks the effective config with `sshd -T`. It confirms sshd is listening on the configured port before touching UFW, and rolls back if any step fails.
- **Containers:** all run with `no-new-privileges` and `cap_drop: ALL`. Traefik adds back only `NET_BIND_SERVICE`, and Ollama only `SYS_RESOURCE`. Every container has memory, CPU and PID limits and a health check. Traefik's root filesystem is read-only.
- **Docker socket:** Traefik reaches Docker only through docker-socket-proxy. The proxy exposes a read-only API subset (no `POST`, no exec) on an internal network. It is the only container that mounts `/var/run/docker.sock`, and it mounts it read-only.
- **Logs:** container logs rotate host-wide (json-file, 10 MB x 3, in `/etc/docker/daemon.json`), unless you already configured a log driver. Traefik logs to stdout, access log included.

## Supply chain

| Component | How it is pinned |
|---|---|
| Container images | A tag in `docker-compose.yml` plus a digest lock in `docker-compose.lock.yml`. The lock is always part of `COMPOSE_FILE`, and `security-check.sh` fails any container whose image is not digest-pinned. See [updating.md](updating.md#container-images). |
| Tailscale, mise | Vendor apt repositories. Before setup.sh writes the keyring, it checks each signing key against the fingerprint in `scripts/lib/pins.sh`. apt then verifies every package, and unattended-upgrades installs updates from both repositories automatically. |
| Dev toolchain, AI CLIs, Exegol CLI | Installed by mise, which verifies checksums (plus cosign, SLSA or GitHub attestations where the vendor publishes them). Versions float to the latest stable release at install time. |
| Oh My Zsh | Fixed commit in `scripts/lib/pins.sh`. In-shell auto-update is disabled. |
| LazyVim | Only the starter template is installed. lazy.nvim fetches the plugins, unpinned, on first launch. |
| Release tarball | Built monthly and signed with cosign keyless. See [updating.md](updating.md#install-from-a-signed-release). |

DevBox does not pin Exegol images. They come from the Exegol CLI.

## Credentials

| Secret | Location (mode 0600) | How to rotate |
|---|---|---|
| Ollama API basic auth | `~/docker/.secrets/ollama-auth.txt` (`ollama:<password>`) | Run `~/docker/rotate-ollama-auth.sh`. Traefik picks up the change within seconds and Open WebUI is unaffected. Then update your clients. |
| Traefik dashboard basic auth | `~/docker/.secrets/traefik-dashboard.txt` (`admin:<password>`) | Delete the file, then run `sudo ./setup.sh` from your checkout. A new credential is generated and the middleware re-rendered. |
| Open WebUI session key | `WEBUI_SECRET_KEY` in `~/docker/ollama-openwebui/.env` | Replace the value (for example with `openssl rand -hex 32`), then run `~/docker/start-all.sh`. Everyone is logged out. |
| Operator password (only when setup created the user) | `~/docker/.secrets/user-password.txt` | Store it somewhere safe and delete the file. Change it with `passwd` if you like. |
| OVH API token (HTTPS mode) | `~/.config/devbox/ovh.env`, copied to `~/docker/traefik/ovh.env` | Create a new token and edit `~/.config/devbox/ovh.env`. Run `sudo ./setup.sh` and `~/docker/start-all.sh`, then revoke the old token at OVH. |

`~/docker/.secrets/` is mode 0700. The middlewares in `~/docker/traefik/dynamic/*-auth.yml` hold apr1 hashes of these credentials. They are mode 0640, and Traefik reads them through the operator's group (`group_add` with `DEVBOX_GID`). setup.sh re-renders them on every run, so don't edit them by hand. Backups contain all of the secrets above, so [encrypt them](ops.md#encryption).

## Open WebUI accounts

The first account you create at `http://ai.internal` becomes the admin. setup.sh starts with signup open so that you can create it.

After that, turn off new sign-ups in **Admin Panel → Settings → General**. Do this in Open WebUI itself. After the first start, Open WebUI stores the setting in its database, so changing `ENABLE_SIGNUP` in `.env` has no effect on an existing install. `security-check.sh` reads the live setting from the running app.

While signup is open, anyone who can reach `ai.internal` can register. By default, Open WebUI gives new accounts the `pending` role until an admin approves them.

## Checking it: security-check.sh

```bash
~/docker/security-check.sh     # exit 1 if any check FAILs
```

The script is read-only. It uses the passwordless `sudo ufw` and `sudo sshd -T` entries that setup.sh installs.

| Check | FAIL or warning means | Fix |
|---|---|---|
| No container publishes on `0.0.0.0` / `::` | A container is reachable from the internet despite UFW | Remove the `ports:` entry, or bind it to the Tailscale IP |
| Host listeners on all interfaces (warning) | A host process listens on all interfaces. UFW filters it. Exegol noVNC shows up here as expected. | Check that it's intended: `sudo ss -ltnp` |
| UFW active, default deny incoming | The firewall is off or permissive | Re-run `sudo ./setup.sh` |
| sshd: port, `passwordauthentication no`, `permitrootlogin no`, `kbdinteractiveauthentication no` | Another file overrides the drop-in, or the port changed | Re-run `sudo ./setup.sh`. It names the overriding file if there is one. |
| Each container: running, healthy, `no-new-privileges`, caps dropped, memory limit, not privileged, digest-pinned | The stack is stopped or unhealthy, or it was started without the lock file | `~/docker/start-all.sh`. Use compose only from inside `~/docker/<service>`. |
| Only docker-socket-proxy mounts `docker.sock` (warning) | Another container can control Docker, which is root-equivalent | Remove that mount |
| Secret file modes (700 for `.secrets`, 600 for secret files, 640 for the `*-auth.yml` middlewares) | Credentials are readable by other users | `chmod` to the expected mode, or re-run setup |
| Open WebUI sign-up open, leftover `user-password.txt` (warnings) | The running Open WebUI still accepts sign-ups (it checks `/api/config`), or the generated password is still on disk | See [Open WebUI accounts](#open-webui-accounts) and [Credentials](#credentials) |
