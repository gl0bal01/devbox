# DevBox

DevBox turns a fresh Ubuntu 24.04 server into a private development, pentest and local-AI workstation that you reach over Tailscale. One script, `setup.sh`, hardens the host, installs a developer toolchain and deploys a small Docker Compose stack (Traefik, Ollama, Open WebUI). SSH is the only port open to the internet.

- **Hardened host:** key-only SSH on a custom port (default 5522), fail2ban, UFW deny-by-default, Docker log rotation.
- **Tailscale-only services:** Traefik publishes ports on the Tailscale IP only, and every route also checks the client address against the Tailscale ranges. Optional HTTPS uses Let's Encrypt (OVH DNS-01) and stays Tailscale-only.
- **Local AI:** Ollama (CPU or NVIDIA GPU) and Open WebUI at `http://ai.internal`. The Ollama API is at `http://ollama.internal`, behind basic auth.
- **Toolchain (installed with mise):** Node LTS, Bun, Rust, uv, Neovim with LazyVim, lazygit, lazydocker, zellij and Exegol, plus zsh with Oh My Zsh. AI coding CLIs are optional.
- **Operations:** backup and restore (age-encrypted when you configure recipients), systemd units for boot start and daily backups, and a security self-check.
- **Pinned supply chain:** images are pinned by tag and digest lock, vendor apt keys by fingerprint. A signed release tarball is published monthly.

```
 laptop / phone ── Tailscale ──┐
                               v
 ┌──────────────────────── Ubuntu 24.04 host ────────────────────────┐
 │ sshd :5522 (public, key-only)            UFW: deny everything else │
 │                                                                    │
 │ Traefik on <tailscale-ip>:80 (+ :443 in HTTPS mode)                │
 │   ai.internal      -> Open WebUI ──> http://ollama:11434 (direct)  │
 │   ollama.internal  -> Ollama API        (basic auth)               │
 │   traefik.internal -> dashboard         (basic auth)               │
 │ docker-socket-proxy: read-only Docker API for Traefik              │
 │                                                                    │
 │ Exegol: host network, noVNC port opened on tailscale0 only         │
 └────────────────────────────────────────────────────────────────────┘
```

The reasons behind each design choice are in [ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements

- Ubuntu 24.04 (other releases get a warning and are untested).
- Docker Engine with the Compose v2 plugin, installed beforehand (`docker-ce` + `docker-compose-plugin`, or Ubuntu's `docker.io` + `docker-compose-v2`).
- Root access, an SSH public key and a Tailscale account.
- Enough RAM for the models you plan to run, plus about 2 GB for Open WebUI. Ollama's memory limit defaults to 8 GB.
- For GPU inference: the NVIDIA driver and the NVIDIA Container Toolkit, then set `DEVBOX_GPU=nvidia`.

## Quick start

```bash
git clone https://github.com/gl0bal01/devbox.git && cd devbox

export SSH_PUBLIC_KEY="ssh-ed25519 AAAA... you@laptop"  # required: password login is disabled at the end
export TAILSCALE_AUTHKEY=tskey-auth-...                 # optional: skips the interactive login URL

./setup.sh --dry-run    # runs every preflight check and prints the plan; changes nothing, no root needed
sudo -E ./setup.sh      # -E passes the exported variables through sudo
```

Then:

1. **Test SSH from a new terminal before you close the current one:** `ssh -p 5522 dev@<server-ip>`.
2. **Start the stack** (as `dev`): `~/docker/start-all.sh`.
3. **Map the host names on each client** to the server's Tailscale IP (`tailscale ip -4` on the server) by adding this line to `/etc/hosts`:
   `100.x.y.z  ai.internal traefik.internal ollama.internal exegol.internal`
4. **Pull a model:** `docker exec ollama ollama pull llama3.2` (the zsh alias is `opull llama3.2`).
5. **Create the Open WebUI admin account** at `http://ai.internal` (the first account becomes admin). Then turn off sign-ups in Admin Panel > Settings > General. Open WebUI stores this setting in its database, so editing `.env` later has no effect.
6. **Verify:** `~/docker/security-check.sh`.
7. **Optional, start on boot and back up daily:** `sudo ~/docker/install-systemd.sh`, then `sudo systemctl start devbox.service`.

Credentials are generated once and kept in `~/docker/.secrets/` (mode 0600):

| File | Contents |
|---|---|
| `traefik-dashboard.txt` | `admin:<password>` for `http://traefik.internal` |
| `ollama-auth.txt` | `ollama:<password>` for `http://ollama.internal` |
| `user-password.txt` | sudo password for `dev`, written only when setup created the user. Store it, then delete the file. |

## Configuration

Environment variables apply on the first install. `setup.sh` saves the effective values to `~/.config/devbox/config.env` (see [config.env.example](config.env.example)), and later runs reuse them unless you set the variable again.

| Variable | Default | Purpose |
|---|---|---|
| `DEVBOX_USER` | recorded operator, else `dev` | Operator account. Re-runs read it from `/etc/devbox/operator`; older installs need it once if the operator is not `dev`. |
| `DEVBOX_SSH_PORT` | `5522` | SSH port |
| `SSH_PUBLIC_KEY` | — | Operator key. Fallbacks: `$HOME/.ssh/devbox_authorized_key`, `/root/.ssh/devbox_authorized_key`, or the user's existing `authorized_keys` |
| `TAILSCALE_AUTHKEY` | — | Join the tailnet without the interactive login |
| `DEVBOX_TAILSCALE_UP_ARGS` | — | Extra `tailscale up` flags, e.g. `--advertise-tags=tag:devbox` |
| `DEVBOX_ALLOW_NO_TAILSCALE` | `false` | `true` binds services to 127.0.0.1 when Tailscale is not up (CI) |
| `ENABLE_HTTPS` | `false` | Let's Encrypt certificates via OVH DNS-01 |
| `DEVBOX_DOMAIN` | — | HTTPS hosts `ai.<domain>` and `ollama.<domain>` |
| `DEVBOX_EMAIL` | — | ACME account email (HTTPS) |
| `DEVBOX_OVH_ENV` | `~/.config/devbox/ovh.env` | OVH API credentials (HTTPS), see [docs/https-setup.md](docs/https-setup.md) |
| `DEVBOX_GPU` | `none` | `nvidia` adds the GPU overlay; needs the NVIDIA runtime in Docker |
| `DEVBOX_FORCE_ZSHRC` | `false` | Replace a `~/.zshrc` that DevBox did not write |
| `MISE_GITHUB_TOKEN` | — | Avoids GitHub API rate limits during `mise install` |

| Flag | Effect |
|---|---|
| `-y`, `--yes` | No prompts. Foreign UFW rules are kept (with a warning), never reset. Needs Tailscale up, `TAILSCALE_AUTHKEY`, or `DEVBOX_ALLOW_NO_TAILSCALE=true`. |
| `--dry-run` | Preflight checks, plan and the file diff for `~/docker`. No changes, no root. |
| `--check` | Report drift between the repo contract and the installed one. No root. |
| `--no-upgrade` | Skip `apt-get upgrade`. |
| `--no-dev-tools` | Skip mise, Oh My Zsh, LazyVim and `.zshrc`. |

Re-running `setup.sh` is safe. It keeps the generated credentials, your `.env` edits, keys you add to `config.env`, the SSH port and the ACME state, and re-renders everything derived from them (Traefik is recreated when its static config changes). Non-critical steps (mise, Oh My Zsh, LazyVim, fail2ban) do not abort the run: setup finishes, lists the failures and exits 1.

Per-service tuning lives in `~/docker/<service>/.env`. Open WebUI's memory limit is `OPENWEBUI_MEM_LIMIT` (default `2g`). For Ollama the keys are `OLLAMA_MEM_LIMIT`, `OLLAMA_CPUS`, `OLLAMA_KEEP_ALIVE`, `OLLAMA_NUM_PARALLEL`, `OLLAMA_MAX_LOADED_MODELS` and `OLLAMA_CONTEXT_LENGTH` (see `services/ollama-openwebui/.env.example`). Apply changes with `start-all.sh`.

### HTTPS

Set `ENABLE_HTTPS=true`, `DEVBOX_DOMAIN`, `DEVBOX_EMAIL` and the OVH credentials before running setup. Traefik then listens on `<tailscale-ip>:443` as well and requests certificates through the DNS-01 challenge. To skip hosts-file edits, point a DNS record `*.<domain>` at the Tailscale IP: the name is public, but only tailnet members can reach it. The `.internal` names keep working over HTTP. Details: [docs/https-setup.md](docs/https-setup.md).

## Daily operations

The helpers live in `~/docker/` and also have zsh aliases (in parentheses). Most have a `make` target in the repo.

| Helper | Purpose |
|---|---|
| `start-all.sh` / `stop-all.sh` (`start-all`, `stop-all`) | Start the services in order and wait for health checks / stop them (volumes are kept) |
| `status.sh` (`status`) | Container health, Tailscale status, URLs, credential paths |
| `security-check.sh` (`security-check`) | Verifies exposure, UFW, effective sshd settings, container hardening, digest pins and secret file modes, and warns while Open WebUI sign-ups are open. Exits 1 on failure. |
| `backup.sh` / `restore.sh` (`devbox-backup`, `devbox-restore`) | See [Backup and restore](#backup-and-restore) |
| `rotate-ollama-auth.sh` | New Ollama API password. Traefik applies it within seconds; Open WebUI is not affected. |
| `install-systemd.sh` | `sudo`: installs `devbox.service` (boot start) and `devbox-backup.timer` (daily) |
| `diagnose.sh` (`devbox-diagnose`) | Writes `~/devbox-diagnose-<time>.tar.gz` (logs, status, firewall; no secrets) |
| `install-ai-dev-stack.sh` | AI CLIs through mise: `--all`, `--update`, `--status`, or names from `claude opencode goose llm fabric` |
| `htb-vpn.sh`, `exegol-start.sh`, `exegol-reset-vnc.sh` | See [Pentest workflow](#pentest-workflow) |

Inside `~/docker/<service>/`, plain `docker compose ps|logs|up -d` loads the full compose chain and the digest lock. Traefik logs go to `docker logs traefik`.

From your laptop, `scripts/laptop/ollama-setup.sh` adds the shell functions `ask`, `askcode`, `chat` and `ollamals`, which call the remote Ollama API with the basic-auth credential. Usage is in the script header.

## Backup and restore

`backup.sh` writes `~/.local/share/devbox/backups/devbox-backup-<UTC>.tar`, which contains:

- every Compose volume of the stack, including the Let's Encrypt state in HTTPS mode, except the Ollama models (they can be re-pulled; the output of `ollama list` is saved instead);
- the credentials, `config.env`, the Exegol workspace and each service's `.env`.

Containers that use a volume are paused while it is archived, so the Open WebUI database is captured in a consistent state. If `~/.config/devbox/age-recipients.txt` exists, the archive is encrypted with `age`. Otherwise it falls back to `BACKUP_GPG_RECIPIENT` from config.env, or stays plaintext (mode 0600) with a warning. The 14 newest archives are kept (`DEVBOX_BACKUP_KEEP`).

`restore.sh [--yes] <archive>` decrypts the archive (`.age` archives use `~/.config/devbox/age-identity.txt` or `AGE_IDENTITY`), asks for confirmation, stops the stack, restores files and volume contents, and starts the stack again. It then prints the `ollama pull` commands for your models. It validates the whole archive before stopping anything, and restores data only: this host's configuration (Tailscale IP, SSH port, HTTPS/GPU mode, compose chain) is kept. To move to a new host, run `setup.sh` there first, then restore. More in [docs/ops.md](docs/ops.md).

## Updating

- **DevBox itself:** `git pull`, then `sudo -E ./setup.sh --yes`, then `~/docker/start-all.sh`. This also applies new image digests.
- **Images:** a monthly CI job refreshes the digest locks within the pinned tags and opens a pull request. Minor and major version bumps are manual tag edits.
- **Toolchain:** `mise upgrade` (as `dev`). AI CLIs: `~/docker/install-ai-dev-stack.sh --update`. Apt packages, including those from the Tailscale and mise repositories, are patched automatically by unattended-upgrades, which setup enables.
- **Signed release:** each month, if `main` changed, CI publishes `devbox.tar` signed with cosign keyless. Verify it before you install from it:

```bash
gh release download <tag> -R gl0bal01/devbox -p 'devbox.tar*'
sha256sum -c devbox.tar.sha256
cosign verify-blob devbox.tar --bundle devbox.tar.sigstore.json \
  --certificate-identity 'https://github.com/gl0bal01/devbox/.github/workflows/monthly-rebuild.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
```

See [docs/updating.md](docs/updating.md).

## Pentest workflow

```bash
htb-vpn ~/htb/lab.ovpn            # start the OpenVPN tunnel (default file: ~/htb/lab.ovpn)
htb-vpn status                    # or: htb-vpn stop
exegol-up                         # Exegol container "htb", noVNC desktop on port 45377
exegol-up osint --port 45378      # a second container on another port
exegol-reset exegol-htb           # rotate the noVNC password
```

The desktop is at `http://exegol.internal:<port>/vnc.html` (user `root`; the password is printed once). Exegol uses host networking, so `exegol-start.sh` opens the port in UFW on `tailscale0` only. The rule stays after the container stops. Each container's workspace is `~/docker/exegol-workspace/<name>`, which backups include. The `exegol` command is the upstream CLI. See [docs/exegol.md](docs/exegol.md).

## Security model

- The boundary is Tailscale ACLs plus SSH keys plus UFW. Only SSH is public. Docker publishes ports past UFW, which is why every published port is bound to the Tailscale IP and `security-check.sh` fails on any port bound to all interfaces.
- `dev` belongs to the `docker` group, which is equivalent to root. The NOPASSWD sudo entries (ufw, tailscale, openvpn, `sshd -T`, stopping the HTB tunnel) are a convenience, not a privilege boundary.
- Containers run with `no-new-privileges`, all capabilities dropped (Traefik keeps `NET_BIND_SERVICE`) and memory limits. Traefik reaches Docker only through a read-only socket proxy.

Full threat model: [docs/security.md](docs/security.md).

## Troubleshooting

- `make doctor` reports install state, contract drift and container health.
- `~/docker/diagnose.sh` bundles logs and state for a bug report.
- SSH lockout protection: setup checks the effective sshd configuration and confirms sshd is listening on the new port before it touches UFW. If either check fails, it restores the previous SSH configuration and stops.
- A refusal to install into `~/docker` means the directory holds files DevBox does not own. Move them aside.

More in [docs/troubleshooting.md](docs/troubleshooting.md).

## Installed layout

```
~/docker/                       installed runtime; re-runs of setup.sh overwrite tracked files
  lib/                          devbox-contract.sh, devbox-lib.sh, .devbox-marker
  traefik/                      compose files, traefik.yml, dynamic/, .env (+ ovh.env in HTTPS mode)
  ollama-openwebui/             compose files (+ GPU overlay), .env with your tuning
  .secrets/                     generated credentials (0700)
  systemd/                      unit templates for install-systemd.sh
  exegol-workspace/<name>/      Exegol workspaces (backed up)
  *.sh                          helpers
~/.config/devbox/               config.env, ovh.env, age-recipients.txt
~/.local/share/devbox/backups/  backup archives; setup-<time>/ copies of host files setup.sh replaced
```

## Development

`make ci` runs the same jobs as CI: lint, the docs path check, the bats suites, compose validation, and a real install inside a throwaway systemd container. `make ci-fast` skips the install, `make test` runs only the static checks, and `make hooks` enables the pre-push hook. See [CONTRIBUTING.md](CONTRIBUTING.md) and [tests/README.md](tests/README.md).

## Documentation

| Document | Topic |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Design decisions and rejected alternatives |
| [services/README.md](services/README.md) | Compose layout, rendered files, adding a service |
| [docs/security.md](docs/security.md) | Threat model and boundaries |
| [docs/ops.md](docs/ops.md) | Backup, restore, recovery |
| [docs/updating.md](docs/updating.md) | Updates, digest refresh, signed releases |
| [docs/https-setup.md](docs/https-setup.md) | OVH DNS-01 for Tailscale-only HTTPS |
| [docs/exegol.md](docs/exegol.md) | Exegol and VPN workflows |
| [docs/ollama-optimization.md](docs/ollama-optimization.md) | Ollama tuning |
| [docs/remote-ide-setup.md](docs/remote-ide-setup.md) | Using the server from a local IDE |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Common problems |

## License

MIT. See [LICENSE](LICENSE).
