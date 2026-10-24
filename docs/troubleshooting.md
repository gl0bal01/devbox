# Troubleshooting

Each entry gives a symptom, what to check, and the fix. Re-running `sudo ./setup.sh` is safe and fixes most drift. If you need help, attach the output of `~/docker/diagnose.sh` (see [ops.md](ops.md#diagnostics-bundle)).

Topic-specific pages: [HTTPS](https-setup.md#troubleshooting), [Exegol and VPN](exegol.md#troubleshooting), [IDE clients](remote-ide-setup.md#troubleshooting), [security-check results](security.md#checking-it-security-checksh).

## Setup

### setup.sh refuses to start

Preflight runs before any change and lists every problem at once, as `[xx]` lines. Fix them all and run it again. To rerun only the checks, use `./setup.sh --dry-run`, which needs no root. Common causes:

- **No SSH public key.** Pass `SSH_PUBLIC_KEY="ssh-ed25519 ..."`, write the key to `~/.ssh/devbox_authorized_key` (root's when you use sudo), or make sure the operator already has a non-empty `authorized_keys`. Password login is disabled at the end of setup, so a key is mandatory.
- **Docker missing or no Compose v2.** Install Docker Engine together with its Compose plugin (`docker-ce` + `docker-compose-plugin`, or Ubuntu's `docker.io` + `docker-compose-v2`).
- **`--yes needs Tailscale up already...`.** With `--yes` there's nobody to open a login URL. Run `sudo tailscale up` first, or pass `TAILSCALE_AUTHKEY`.
- **HTTPS settings incomplete.** See [https-setup.md](https-setup.md).
- **`DEVBOX_GPU=nvidia but Docker has no nvidia runtime`.** See [GPU](ollama-optimization.md#gpu).
- **`Refusing to install into ~/docker: not a devbox tree`.** The directory holds files DevBox didn't create. Move the listed entries elsewhere.

### "Another setup.sh is running"

Another setup.sh process holds the lock on `/run/devbox-setup.lock`. The lock is released when that process exits, so a leftover file is harmless; don't delete it. Find the holder with `sudo fuser -v /run/devbox-setup.lock`.

### "Completed with failures: ..."

Some steps are non-critical: `mise install`, Oh My Zsh, LazyVim and fail2ban. When one of them fails, setup.sh applies everything else, then exits 1 and names what failed. Fix the cause and re-run setup.

- **mise install** usually fails because of the GitHub API rate limit. Run `sudo MISE_GITHUB_TOKEN=<token> ./setup.sh`; a read-only token is enough. You can also run `mise install` as the operator.
- **fail2ban:** read `journalctl -u fail2ban -n 50`.

## SSH

### Can't log in after setup

setup.sh confirms sshd is listening on the configured port before it changes UFW. If any step fails, it restores the previous sshd configuration. So the usual causes are outside the host:

- **Your provider's firewall or security group** doesn't allow the new port (default 5522). Open it.
- **Wrong command.** Use `ssh -p 5522 dev@<server>`. Root login is disabled.
- **Wrong key offered.** Debug with `ssh -v -i ~/.ssh/<key> -p 5522 dev@<server>`.

From the provider console or a session that's still open:

```bash
sudo sshd -T | grep -E '^(port|passwordauthentication|permitrootlogin) '
sudo ss -ltnp | grep sshd
sudo ufw status
systemctl status ssh.socket ssh.service
```

Ubuntu 22.10 and later use socket activation, so after a port change, `sudo systemctl daemon-reload && sudo systemctl restart ssh.socket` applies it; setup.sh does this for you. If setup aborted with `Effective sshd config lacks ...`, the message names the file that overrides the DevBox drop-in. Remove the setting from that file and re-run setup.

## Network and access

### Services bound to 127.0.0.1, or the wrong IP

**Check:** `docker ps` shows `127.0.0.1:80->80/tcp`, or `grep TAILSCALE_IP ~/docker/traefik/.env` doesn't match `tailscale ip -4`.

**Cause:** the install used `DEVBOX_ALLOW_NO_TAILSCALE=true`, or the node was re-added to the tailnet and got a new IP.

**Fix:** `sudo tailscale up`, then `sudo ./setup.sh`, then `~/docker/start-all.sh`.

### A client can't reach ai.internal

1. Is the client on the tailnet? Check with `tailscale status` and `tailscale ping <server>`.
2. Does the name resolve to the server's Tailscale IP? Check `/etc/hosts` (or DNS for the HTTPS names).
3. On the server, `docker ps` must show Traefik on `<tailscale-ip>:80->80/tcp`.
4. Do your tailnet ACLs allow ports 80 and 443 to the server?

The HTTP status from `curl -sI http://ai.internal` narrows it down:

- **Timeout:** network, ACL or DNS (steps 1-4).
- **404:** no router matches the host name; check the spelling.
- **403:** see below.
- **502/504:** the backend container is down; see [unhealthy services](#a-service-is-unhealthy-or-restarting).

### 403 Forbidden from Traefik

The request's source address isn't in the allowlist (Tailscale ranges and loopback). This typically happens when traffic arrives through a subnet router or proxy that rewrites the source to a LAN address. Connect with the Tailscale client directly. The allowlist is defined in `services/traefik/dynamic/middlewares-allowlist.yml`. If you deliberately need another range, change it in the repo and re-run setup.

### 401 Unauthorized on ollama.internal

The client sends no credential, or an old one.

- Read the current credential on the server: `cat ~/docker/.secrets/ollama-auth.txt`.
- After `rotate-ollama-auth.sh`, update every client. Laptop helpers are refreshed by re-running `scripts/laptop/ollama-setup.sh`.
- If even the current credential fails, check that `~/docker/traefik/dynamic/ollama-auth.yml` exists. Look for `middleware ... does not exist` in `docker logs traefik`, and re-run setup.

## Containers

### A service is unhealthy or restarting

```bash
cd ~/docker/<service>             # traefik or ollama-openwebui
docker compose ps
docker compose logs --tail 100 <container>
docker inspect -f '{{.State.OOMKilled}} {{.State.ExitCode}}' <container>
```

- `start-all.sh` waits up to 180 s per service. A timeout means a health check never passed.
- `TAILSCALE_IP unset`, `DEVBOX_GID unset` or `WEBUI_SECRET_KEY unset`: compose was run outside `~/docker/<service>`, or the `.env` file is missing or predates the current setup.sh. Run compose from the install directory, or re-run setup.
- `network proxy-net ... could not be found`: run `~/docker/start-all.sh`, which creates it, or `docker network create proxy-net`.
- Traefik reports `address already in use`: another process holds port 80 or 443. Find it with `sudo ss -ltnp 'sport = :80'`.
- `OOMKilled true`: the container hit its memory limit. For Ollama, see the next entry.

### Ollama fails to load a model, or is OOM-killed

The model and its context cache don't fit in `OLLAMA_MEM_LIMIT` (8g by default). Raise the limit or use a smaller or more quantized model. See [ollama-optimization.md](ollama-optimization.md).

### GPU not used

See [ollama-optimization.md](ollama-optimization.md#gpu).

### Disk full

Check with `docker system df` and `df -h /var/lib/docker`. Models are the usual culprit: list them with `docker exec ollama ollama list` and remove one with `docker exec ollama ollama rm <model>`. `docker image prune -a` removes unused images. Never run `docker volume prune --all` while the stack is stopped. Named volumes with no container attached would be deleted, including Open WebUI data, certificates and models.

## Backups and checks

### backup.sh warns "backup is NOT encrypted"

No age recipients or GPG recipient is configured. See [ops.md](ops.md#encryption).

### security-check.sh reports FAIL

Each check, what it means and its fix are listed in [security.md](security.md#checking-it-security-checksh).

### Commands missing in sudo or root shells

mise activates only in the operator's login shells. It's deliberately skipped under sudo, so tools such as `exegol`, `nvim` and `lazygit` aren't on root's `PATH`. Run them as the operator.
