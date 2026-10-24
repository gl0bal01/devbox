# Operations

This page covers backups, restore, the setup.sh snapshots, systemd units and incident response. The day-to-day helpers in `~/docker/` are listed in [README.md](../README.md), and fixes for specific symptoms are in [troubleshooting.md](troubleshooting.md).

## Working with the installed stack

- Each service lives in `~/docker/<service>/`. Its `.env` sets `COMPOSE_FILE` to the full chain: base, then the HTTPS and GPU overlays when enabled, then the digest lock. A plain `docker compose ps|logs|up -d` inside that directory therefore uses the same configuration as `start-all.sh`. Don't pass `-f`.
- setup.sh never runs `docker compose`. After re-running it, apply the changes with `~/docker/start-all.sh`, which recreates whatever changed.
- `docker compose restart` does not re-read `.env`. Use `docker compose up -d` (or `start-all.sh`) after editing it.
- Re-running setup.sh mirrors the repo into each `~/docker/<service>/`. It replaces files you changed there and deletes files you added. Exceptions: dotfiles (such as each `.env`), `traefik/ovh.env` and the generated `traefik/dynamic/*-auth.yml`. The helper scripts in `~/docker/` are overwritten too. `~/docker/.secrets/` is kept. Make any other change in the repo and re-run setup.

## Backups

`~/docker/backup.sh` writes one archive to `~/.local/share/devbox/backups/devbox-backup-<UTC>.tar`, with `.age` or `.gpg` appended when encrypted:

| Member | Content |
|---|---|
| `MANIFEST` | Creation time, host, contract version, list of archived volumes |
| `volumes/<volume>.tgz` | Every Compose volume of the stack except `ollama-openwebui_ollama-data`: Open WebUI data, plus the certificates in `traefik_letsencrypt` in HTTPS mode |
| `files.tgz` | `~/docker/.secrets`, `~/.config/devbox`, `~/docker/exegol-workspace`, and each service `.env`, with paths relative to the home directory |
| `ollama-models.txt` | Output of `ollama list`, so you can re-pull the models after a restore |

Models are left out because they are large and can be downloaded again. While a volume is being archived, the containers using it are paused for a few seconds, so Open WebUI's database is captured in a crash-consistent state. The newest 14 archives are kept. To change that, set `DEVBOX_BACKUP_KEEP` in the environment for manual runs, or for the timer with `sudo systemctl edit devbox-backup.service` and a line `Environment=DEVBOX_BACKUP_KEEP=30` under `[Service]`.

Archives stay on the server's disk. Copy them somewhere else regularly, for example from your laptop:

```bash
rsync -av -e 'ssh -p 5522' dev@<server>:.local/share/devbox/backups/ ./devbox-backups/
```

### Encryption

Archives contain every credential. If no recipient is configured, backup.sh writes a plaintext archive (mode 0600) and prints a warning.

**age (preferred).** Generate the key pair on a machine other than the server, so that someone who compromises the server can't decrypt old backups:

```bash
# laptop
age-keygen -o devbox-backup.key          # prints "Public key: age1..."
# server: only the public key goes here
echo 'age1...' > ~/.config/devbox/age-recipients.txt
```

You need the private key only to restore. Don't store it in `~/.config/devbox/` permanently: that directory is part of every backup.

**GPG.** Import the recipient's public key into the operator's keyring and add `BACKUP_GPG_RECIPIENT=<key id>` to `~/.config/devbox/config.env`. setup.sh only manages its own keys in that file, so this one survives re-runs. age takes precedence if `age-recipients.txt` exists.

### Daily backups

The `devbox-backup.timer` runs `backup.sh` once a day, at a random time between 00:00 and 00:30 server time. If the server was off at that time, the backup runs at the next boot. See [systemd units](#systemd-units). Logs:

```bash
journalctl -u devbox-backup.service
```

## Restore

`restore.sh` is destructive. It stops the stack, overwrites the archived files under your home directory, re-renders the auth middlewares, creates any missing containers and volumes, replaces the contents of every archived volume, and starts the stack again.

```bash
~/docker/restore.sh ~/.local/share/devbox/backups/devbox-backup-<UTC>.tar.age
```

- It asks for confirmation; `--yes` skips the prompt.
- `.age` archives are decrypted with `~/.config/devbox/age-identity.txt`, or with the file named in `AGE_IDENTITY`. Copy your private key over for the restore and delete it afterwards:

  ```bash
  AGE_IDENTITY=/path/to/devbox-backup.key ~/docker/restore.sh <archive>
  ```
- `.gpg` archives need the private key in the operator's keyring.
- At the end it prints the `docker exec ollama ollama pull <model>` commands for the models listed in the archive.

### Moving to a new server

1. Install DevBox on the new server (see [README.md](../README.md)).
2. Copy the archive and your age private key to the new server.
3. Run `~/docker/restore.sh <archive>`. It restores data only and keeps this host's configuration (Tailscale IP, SSH port, HTTPS and GPU mode, compose chain), so nothing is rebound or reconfigured. Volumes this host's stack does not use (for example Let's Encrypt state from an HTTPS host) are skipped with a warning.
4. Recommended: run `sudo ./setup.sh` from your checkout, then `~/docker/start-all.sh`. The restored `config.env` and service `.env` files carry the old server's settings, such as HTTPS, GPU and the compose chain, and setup.sh makes them consistent with this host. If the old server had `GPU=nvidia` and the new one has no GPU, pass `DEVBOX_GPU=none`.
5. Re-pull the models with the commands restore.sh printed.

## setup.sh snapshots

Before setup.sh replaces one of the files below, it copies it to `~/.local/share/devbox/backups/setup-<UTC>/`. The copy is named after the full path, with `/` replaced by `_` (names below are for the default user `dev`):

| Original | Snapshot name |
|---|---|
| `/etc/sudoers.d/90-dev` | `_etc_sudoers.d_90-dev` |
| `/etc/ssh/sshd_config.d/00-devbox.conf` | `_etc_ssh_sshd_config.d_00-devbox.conf` |
| `/etc/docker/daemon.json` (only when setup adds log rotation) | `_etc_docker_daemon.json` |
| `~/.config/devbox/config.env` | `_home_dev_.config_devbox_config.env` |
| `~/.zshrc` | `_home_dev_.zshrc` |

To roll back one file, copy it back and reload the service. For example:

```bash
sudo cp ~/.local/share/devbox/backups/setup-<UTC>/_etc_docker_daemon.json /etc/docker/daemon.json
sudo systemctl restart docker
```

`~/docker/` itself is not snapshotted (see [Working with the installed stack](#working-with-the-installed-stack)). Snapshot directories are never pruned automatically; delete old `setup-*` directories by hand.

## systemd units

```bash
sudo ~/docker/install-systemd.sh        # or, from the repo: make install-systemd
sudo systemctl start devbox.service     # units are enabled, not started
```

- `devbox.service` runs `start-all.sh` as the operator after Docker and tailscaled are up. Stopping the unit runs `stop-all.sh` (`docker compose down`, volumes kept).
- `devbox-backup.timer` triggers `devbox-backup.service`, which runs `backup.sh`. To run a backup now: `sudo systemctl start devbox-backup.service`.
- Status: `systemctl status devbox.service` and `systemctl list-timers devbox-backup.timer`.
- The installed units are rendered from `~/docker/systemd/*.template`. setup.sh refreshes the templates but not the installed units, so re-run `install-systemd.sh` after an update that changes them.
- To remove the units: `make uninstall-systemd` from the repo.

## Incident response

If you suspect a compromise:

1. **Cut access.** In the Tailscale admin console, remove unknown devices, revoke auth keys, and if necessary remove the server node itself. If SSH may be abused, close the SSH port in your provider's firewall and use the provider console.
2. **Capture state** before you change anything: `~/docker/diagnose.sh` (no secrets), `journalctl --since -2d`, `last`, `sudo ufw status numbered`, `docker ps -a`.
3. **Replace SSH keys.** Edit `~/.ssh/authorized_keys`: remove the compromised key and add a new one. Login is key-only, so do this from an existing session or the provider console.
4. **Rotate every credential.** See the table in [security.md](security.md#credentials). Rotate the OVH token too if HTTPS is enabled.
5. **Rebuild if root may be lost.** A stolen operator key or Docker access means root. Build a fresh server, install DevBox, restore a backup from before the incident (see [Moving to a new server](#moving-to-a-new-server)), and rotate the credentials again, because the restore brings back the old ones.

After re-authenticating Tailscale on the server (`sudo tailscale logout && sudo tailscale up`), check `tailscale ip -4`. If the IP changed, run `sudo ./setup.sh` and `~/docker/start-all.sh`.

## Diagnostics bundle

```bash
~/docker/diagnose.sh     # writes ~/devbox-diagnose-<UTC>.tar.gz (mode 0600)
```

The bundle contains compose status and images, the last 500 log lines of each container, Tailscale status, UFW rules, listeners, `docker info`, `daemon.json`, a filtered `config.env`, and the `security-check.sh` output. It never collects `.env` files, `ovh.env` or `.secrets/`. Container logs can still include hostnames and IPs, so review the bundle before you share it.
