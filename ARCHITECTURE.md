# DevBox Architecture

This file records the decisions that shape DevBox. Each entry gives the decision, the drivers behind it, the alternatives that were rejected, and the consequences that were accepted. Read the relevant entry before you change install layout, networking, HTTPS, pinning, downloads, backups, systemd or CI, and update the entry when the decision changes. Usage instructions are in [README.md](README.md).

## Trust boundary: the network, not local privilege

**Decision.** The security boundary is Tailscale ACLs plus SSH key authentication plus UFW deny-by-default. Inside that boundary the operator is in the `docker` group, which is equivalent to root. The NOPASSWD sudo entries in `/etc/sudoers.d/90-<user>` (ufw, tailscale, openvpn, `sshd -T`, and `pkill -F /run/devbox/htb-vpn.pid openvpn`) exist so the helpers can run without a password prompt. They are not a privilege boundary.

**Drivers.** Exegol and most pentest tooling need privileged Docker. A boundary that prevents reach is worth more than local separation that the Docker socket bypasses anyway.

**Rejected.** Rootless Docker and userns-remap: both break Exegol and volume ownership. A sudoers allowlist presented as least privilege: false security next to the Docker socket.

**Consequences.**
- Compromise of the operator account or its SSH key means root.
- A compromised tailnet device can reach the services. Basic auth on the Ollama API and the Traefik dashboard, and the Open WebUI login, still stand in the way.
- Local privilege escalation is out of scope. [docs/security.md](docs/security.md) states this to operators.

## Bootstrapper and installed tree

**Decision.** The repository is the source of truth. `setup.sh` converges the host, syncs `services/`, `scripts/host/`, `scripts/lib/` and `scripts/systemd/` into `~/docker/`, renders templates, writes `~/.config/devbox/config.env` and the install marker, and exits. Helpers run from `~/docker/` and locate the install from their own path. Installed files fall into three classes:

- **Tracked:** mirrored with `rsync --delete` on every run.
- **Operator-owned:** each service `.env`, `ovh.env` and the credentials in `.secrets/`. Created once, never overwritten.
- **Derived:** the basic-auth middlewares, the HTTPS `traefik.yml`, the keys setup manages inside `.env` (`COMPOSE_FILE`, `TAILSCALE_IP`, `DEVBOX_GID`, `DOMAIN`) and its own keys in `config.env`. Rendered or upserted again on every run from persisted state.

**Drivers.** Configuration generated from heredocs inside the installer drifted from the tracked files and could not be reviewed or tested. Because re-running setup is the upgrade path, every run must converge and must preserve operator state.

**Rejected.** Heredoc-generated configuration. Symlinking `~/docker` into the checkout: it ties the runtime to a working tree and causes permission problems. Running helpers from the repository.

**Consequences.**
- Hand edits to tracked files under `~/docker` are lost on the next run. Tuning goes in `.env`.
- Host files that setup replaces (sudoers, `daemon.json`, the sshd drop-in, `.zshrc`, `config.env`) are copied to `~/.local/share/devbox/backups/setup-<time>/` first.
- A collision guard refuses a non-empty `~/docker` that holds entries DevBox does not own, unless it is a prior install (contract and marker both present).
- Root never sources operator-owned files. `config.env` and `ovh.env` are parsed with `sed`. Setup upserts only its own keys in `config.env`, so keys the operator adds (such as `BACKUP_GPG_RECIPIENT`) survive.
- Setup records the operator in `/etc/devbox/operator`, a root-owned file with mode 0644 in a root-owned directory. When `DEVBOX_USER` is unset, re-runs read the operator from that file, and only if its ownership and mode are intact; otherwise they fall back to `dev`. The operator is never inferred from user-writable paths such as install markers, which any local user could plant. Installs made before this file existed need `DEVBOX_USER` once if the operator is not `dev`.

## Preflight first, lockdown last

**Decision.** A read-only preflight checks everything before the first change: root, OS, Docker and Compose, the GPU runtime, the SSH key, HTTPS inputs, the Tailscale path under `--yes`, and the collision guard. It reports every failure in one pass. `--dry-run` runs the same checks. SSH and firewall changes come last, in this order:

1. Write the sshd drop-in `/etc/ssh/sshd_config.d/00-devbox.conf`.
2. Validate it with `sshd -t`, then check the effective settings with `sshd -T`.
3. Restart sshd, restarting `ssh.socket` when socket activation is enabled.
4. Wait until sshd listens on the new port.
5. Only then change UFW.

Any failure in steps 2 to 4 restores the previous drop-in.

**Drivers.** On a remote host, a half-applied run is the worst outcome, and the classic failure is an SSH lockout. sshd keeps the first value it reads, and cloud images ship `50-cloud-init.conf` with `PasswordAuthentication yes`, so a `99-` drop-in silently loses. On Ubuntu 22.10 and later, sshd is socket-activated, so restarting `ssh.service` alone does not move the port.

**Rejected.** Stopping at the first error, which costs one run per fix. A `99-hardening.conf` drop-in. Relying on `sshd -t`, which validates syntax but not which file wins. Enabling UFW before the new port is confirmed.

**Consequences.**
- Setup refuses to run without an SSH public key, because password login is disabled at the end.
- UFW converges instead of being reset: the SSH rule is tagged `devbox-ssh`, and rules the operator adds (such as Exegol ports) survive re-runs. Foreign rules are listed and only removed if the operator answers yes interactively; `--yes` keeps them.
- Upgrades never move sshd implicitly: the port comes from `DEVBOX_SSH_PORT`, else `config.env`, else the legacy `99-hardening.conf`, else 5522. Rollback restores both our drop-in and the legacy one, and the listener check requires sshd (or systemd's socket) on the port; preflight rejects a port held by another process.
- Non-critical steps (mise, Oh My Zsh, LazyVim, fail2ban) are collected, and setup exits 1 after finishing.
- A lock in `/run/devbox-setup.lock` (root-only directory, unlike `/run/lock`) prevents concurrent runs.

## Runtime contract

**Decision.** `scripts/lib/devbox-contract.sh` declares the ordered service list, container names, Traefik hosts, install paths and backup scope, plus two accessors: `devbox_get` and `devbox_config_get`. `setup.sh` sources the repo copy and installs it to `~/docker/lib/`, and helpers source the installed copy. The file is bash-only (`DEVBOX_SERVICES` is an array) and stays declarative. `DEVBOX_CONTRACT_VERSION` is bumped on schema-incompatible changes, and `setup.sh --check` diffs the repo copy against the installed one.

**Drivers.** Without one declaration site, setup installed services to one path while the helpers iterated another, and variable names disagreed between scripts. Every fresh install silently skipped every service.

**Rejected.** YAML plus a parser: an extra dependency. Constants duplicated across scripts: the original source of drift. Environment variables only: no place where the values are declared.

**Consequences.**
- `tests/contract/contract.bats` checks the contract against the Compose configuration as resolved by Compose: project names, container names, `Host()` rules, and that every backup exclusion names a real volume.
- `security-check.sh`, `status.sh`, `backup.sh` and `diagnose.sh` iterate the contract, so a new service is covered as soon as it is declared.
- Every path derives from `DEVBOX_HOME`, which helpers compute from their own location because `sudo` sets `HOME=/root`.

## Compose chain in each service's `.env`

**Decision.** `setup.sh` writes Compose's native `COMPOSE_FILE` into each service's `.env` as `docker-compose.yml[:docker-compose.https.yml][:docker-compose.gpu.yml]:docker-compose.lock.yml`. A top-level `name:` pins the project names `traefik` and `ollama-openwebui`.

**Drivers.** When the chain lived in `config.env` and the helpers assembled `-f` flags, a plain `docker compose` in the service directory loaded only the base file, and the digest lock was ignored in the default HTTP mode. With native `COMPOSE_FILE`, helpers, operators and systemd all load the same chain.

**Rejected.** A chain in `config.env` read by wrappers, which plain `docker compose` bypasses. Separate file sets per mode: duplication.

**Consequences.**
- The lock always applies, and `security-check.sh` fails any container whose image is not digest-pinned.
- Pinned project names give stable volume names (`ollama-openwebui_ollama-data`, `ollama-openwebui_openwebui-data`) and the label that backups use to discover volumes.
- `scripts/ci/check-compose-config.sh` validates every chain setup can emit.

## Tailscale-only binding, failing closed

**Decision.** Only Traefik publishes ports, and only on `${TAILSCALE_IP:?}`. Other services use `expose` on the shared `proxy-net` network. `TAILSCALE_IP` and `WEBUI_SECRET_KEY` use `${VAR:?}`, so an unset value aborts Compose instead of producing a wildcard bind or an empty secret. The sysctl `net.ipv4.ip_nonlocal_bind=1` lets Docker bind the Tailscale address at boot, before `tailscale0` exists. Hosts without Tailscale (CI) can opt into `DEVBOX_ALLOW_NO_TAILSCALE=true`, which binds to 127.0.0.1.

**Drivers.** Docker publishes ports through DNAT, which bypasses UFW's INPUT rules, so a firewall cannot protect a `0.0.0.0` bind. Binding to the Tailscale address is the control that holds. A `${VAR:-}` default turns a missing IP into a bind on all interfaces.

**Rejected.**
- Binding `0.0.0.0` and filtering with UFW: bypassed by Docker.
- DOCKER-USER or DNAT scoping modules: moving parts for topologies DevBox never creates.
- Waiting for `tailscaled` at boot: races.
- A separate internal network between Open WebUI and Ollama: both already share `proxy-net`, so it isolated nothing.

**Consequences.**
- Three independent checks guard the property: `check-compose-config.sh` (offline, every chain), `contract.bats` (only Traefik publishes, only on `TAILSCALE_IP`) and `security-check.sh` (the running containers).
- Clients need the `.internal` names to resolve to the Tailscale IP.
- If the Tailscale IP changes, re-run `setup.sh`.

## HTTPS as an overlay with DNS-01

**Decision.** HTTPS is opt-in (`ENABLE_HTTPS=true`). Overlay files add port 443 on the Tailscale IP, the OVH credentials (`env_file: ovh.env`, mode 0600), the named volume `letsencrypt` for ACME state (`traefik_letsencrypt`), and TLS routers for `ai.<domain>` and `ollama.<domain>`. Traefik creates and owns `acme.json` inside the volume. `setup.sh` renders `traefik.https.yml.template` over `traefik.yml` to add the `websecure` entrypoint and the Let's Encrypt resolver.

**Drivers.** Some clients require HTTPS with a publicly trusted certificate. The DNS-01 challenge issues one without any public listener. Traefik insists on an `acme.json` with mode 0600 owned by its own uid. With `cap_drop: ALL` it cannot open an operator-owned host file, so the state belongs in a volume Traefik owns.

**Rejected.** HTTP-01, which needs a public port 80. Self-signed certificates or a private CA, which must be distributed to every client. Separate full compose files per mode: duplication. A host-side `letsencrypt/acme.json` created by setup: unreadable to Traefik.

**Consequences.**
- `backup.sh` archives the ACME volume like any other Compose volume.
- On upgrade, a legacy `~/docker/traefik/letsencrypt/` is left untouched and certificates are re-issued.
- Certificate names appear in Certificate Transparency logs. A DNS record `*.<domain>` pointing at the Tailscale IP is public, but only tailnet members can reach it.
- OVH is the only DNS provider wired up. Supporting another means changing the template and the overlay's environment.
- The `.internal` routers and the dashboard stay on HTTP.

## Traefik middlewares on the entrypoints

**Decision.** Every entrypoint applies two middlewares: `default-headers-base` (frame deny, nosniff, referrer policy, `X-Robots-Tag`) and `internal-only`, an allowlist of `100.64.0.0/10`, `fd7a:115c:a1e0::/48` and loopback. The `websecure` entrypoint adds HSTS. Definitions live in `services/traefik/dynamic/`.

**Drivers.** Per-router labels get forgotten on new routers, while entrypoint wiring covers every router by default. The allowlist is defense in depth behind the Tailscale bind.

**Rejected.**
- Per-router middleware labels.
- A rate-limit middleware: it throttled IDE clients and Open WebUI bursts, and every client is already on the tailnet.
- `browserXssFilter`: deprecated, and ignored by current browsers.

**Consequences.** A new service needs only `traefik.enable=true` and its router labels. Loopback stays in the allowlist for in-container health checks.

## Credentials are state, auth middlewares are derived

**Decision.** `setup.sh` generates `traefik-dashboard.txt` and `ollama-auth.txt` once in `~/docker/.secrets/` (directory 0700, files 0600). The Traefik basic-auth middlewares (`dynamic/*-auth.yml`) are rendered from them on every run, and also by `rotate-ollama-auth.sh` and `restore.sh`. Hashes are apr1 and are written verbatim. The middleware files have mode 0640, and Traefik reads them through the operator's group: `group_add: ${DEVBOX_GID:?}`, with `DEVBOX_GID` written to `traefik/.env` by setup. Open WebUI reaches Ollama directly at `http://ollama:11434`, so it never crosses the auth middleware. `WEBUI_SECRET_KEY` is rendered into `.env` once.

**Drivers.** When hashes were regenerated on every run, a re-run broke the credential operators had stored. Rotation used to write `$$`-escaped hashes, which Traefik's file provider reads literally, so rotation broke authentication. `$$` escaping applies only to Compose labels. Traefik runs as root with `cap_drop: ALL`, so it lacks `CAP_DAC_OVERRIDE` and cannot read operator-owned 0600 files.

**Rejected.** Regenerating credentials on every run. Hashes in Compose labels. Adding back `CAP_DAC_OVERRIDE`, which restores root's ability to bypass file permissions. World-readable middleware files. A GPG-encrypted credentials file in `$HOME`: an extra install step that still desynced. Authentication between Open WebUI and Ollama: it would tie Open WebUI to every rotation without adding a boundary on a shared network.

**Consequences.**
- Rotations and re-runs never desynchronize.
- `security-check.sh` expects 0640 on the middleware files and 0600 on the credentials.
- apr1 is weak against offline cracking, which is acceptable for 32-character random passwords.
- Backups include `.secrets/`, and a restore re-renders the middlewares.
- When setup creates the operator account, it writes the sudo password to `user-password.txt`, and `security-check.sh` warns while that file exists.

## Image pinning: tag plus digest lock

**Decision.** Base compose files pin tags. Images get a minor tag where upstream publishes one (`traefik:v3.7`, `open-webui:0.12`) and a patch tag otherwise (`ollama/ollama:0.40.10`, `tecnativa/docker-socket-proxy:v0.5.0`). A generated `docker-compose.lock.yml` per service pins `repo:tag@sha256:<index digest>`. `scripts/update-images.sh` produces it from the base file alone with `docker compose config --lock-image-digests`. PR CI never queries a registry: `contract.bats` checks offline that each lock pins exactly the base tags. A monthly job refreshes the locks through a pull request.

**Drivers.** Tags move and digests do not. Patch releases carry security fixes, so they should arrive without hand edits but still pass review. A PR gate that depends on registries fails for reasons unrelated to the change.

**Rejected.**
- Tags only: not reproducible.
- Digests in the base files: the tag no longer signals what to refresh.
- Hand-edited locks.
- `update-images.sh --check` in PR CI: it fails whenever upstream ships a patch.
- Chaining the old lock while regenerating: the old digest overrides the tag, so nothing ever refreshes.

**Consequences.**
- Index digests resolve per platform, so the locks work on amd64 and arm64.
- Patch-pinned images never move on their own.
- A minor or major bump means editing the tag, running `scripts/update-images.sh --apply`, and committing.

## Host software: vendor apt repositories and mise, no `curl | sh`

**Decision.**
- **Tailscale and mise** come from their vendor apt repositories. Each signing key is downloaded, checked against the fingerprint pinned in `scripts/lib/pins.sh`, and exported into a keyring that holds only that key. The deb822 source references it with `Signed-By`.
- **Developer tools** come from the mise system config (`scripts/install/mise-config.toml`, installed as `/etc/mise/config.toml`). Explicit `aqua:` backends make mise verify checksums, plus cosign, SLSA or GitHub attestations where the vendor publishes them. Exegol is installed with `pypi:`. Versions resolve to the latest at install time.
- **Oh My Zsh** is pinned by commit, with auto-update disabled. The LazyVim starter is not pinned.
- **`scripts/update-pins.sh`** checks that the vendor keys still carry the pinned fingerprints and bumps the Oh My Zsh commit.
- **unattended-upgrades** is installed and enabled (`/etc/apt/apt.conf.d/20auto-upgrades`). `/etc/apt/apt.conf.d/52devbox-unattended-upgrades` adds the Tailscale and mise origins to the default Ubuntu pockets.

**Drivers.** apt verifies every package, and unattended-upgrades patches the vendor repositories as well as Ubuntu's. mise verifies downloads and handles upgrades. The earlier per-tool SHA256 manifest held placeholder hashes, so a fresh install could not complete, and every upstream release would have broken it again.

**Rejected.** A SHA256 manifest with a fetch-and-verify wrapper and an "unverified" bypass. Pinning tool versions in the repo: churn, with no trust gain over mise's verification. Pinning the LazyVim starter: lazy.nvim fetches its plugins unpinned anyway, so pinning the template alone adds nothing.

**Consequences.**
- Toolchain versions differ between installs made at different times. `mise upgrade` updates them.
- A vendor key rotation fails setup and the monthly job until someone verifies the new key out of band and edits `pins.sh`. Fingerprints never change automatically.
- `mise install` can hit GitHub API rate limits. `MISE_GITHUB_TOKEN` avoids them.

## Logging through Docker daemon defaults

**Decision.** `setup.sh` sets `json-file` rotation (10 MB × 3) in `/etc/docker/daemon.json` when no `log-driver` is configured. Compose files carry no logging blocks. Traefik writes its logs and access log to stdout.

**Drivers.** Per-file `x-logging` anchors had to stay byte-identical and needed their own CI check. Daemon defaults also cover Exegol and any other container on the host.

**Rejected.** Per-file anchors with a consistency check. Traefik log files under the install tree, outside Docker's log rotation.

**Consequences.** A log driver chosen by the operator is respected. Docker is restarted once, on the run that changes `daemon.json`.

## Backup and restore

**Decision.**
- **Volumes:** `backup.sh` finds each service's volumes by the `com.docker.compose.project` label, skips `DEVBOX_BACKUP_EXCLUDE_VOLUMES`, pauses the containers that use a volume while archiving it, and runs `tar` inside an image the stack already uses.
- **Files:** it adds `DEVBOX_BACKUP_PATHS` and each service's `.env`.
- **Output:** one archive with a `MANIFEST`, encrypted with age (preferred) or GPG when configured.
- **Restore:** `restore.sh` validates the archive before stopping anything, restores data but keeps the current host's setup-managed keys (`config.env` and the service `.env` chain keys), skips volumes the current stack does not use, tolerates root-owned Exegol files, and re-renders the auth middlewares.

**Drivers.** The previous script used unprefixed volume names and silently archived nothing. Pausing captures SQLite in a consistent state. Reusing an image the stack already trusts avoids pinning and refreshing a separate backup image.

**Rejected.** Hard-coded volume names. A pinned Alpine backup image. Backing up Ollama models, which are large and can be re-pulled; the `ollama list` output is saved instead. Generic per-application backup modules.

**Consequences.**
- Volumes of a new service, and the ACME volume, are backed up automatically.
- Open WebUI pauses briefly during a backup.
- Unencrypted archives contain credentials: they get mode 0600 and a warning.
- Restoring onto a new host needs only `setup.sh` before the restore. Host-specific values are kept, so Traefik binds the new host's Tailscale IP.

## systemd: one stack unit and a backup timer

**Decision.** Three units:

- `devbox.service`: oneshot with `RemainAfterExit`. Runs `start-all.sh` and `stop-all.sh` as the operator. `Requires=docker.service` and starts after `tailscaled` and `network-online`.
- `devbox-backup.service`: a oneshot that runs at idle I/O priority.
- `devbox-backup.timer`: daily, `Persistent`, with a 30-minute random delay.

`install-systemd.sh` renders the templates, verifies them, and enables the units without starting them. It resolves the install from its own location.

**Drivers.** `restart: unless-stopped` already handles crashes. A single unit adds boot ordering and `systemctl` control.

**Rejected.**
- Per-container units: a second restart policy.
- The backup unit requiring the stack unit: a backup would start a stack the operator stopped on purpose.
- Resolving the install from `$HOME`: that is `/root` under `sudo`.

**Consequences.** `tests/contract/systemd.bats` renders the templates and runs `systemd-analyze verify` on them.

## Testing: offline static checks plus a real install

**Decision.** There are two layers:

1. **Static and offline** (CI job `static`, `make test`): `scripts/ci/lint.sh`, `scripts/ci/check-docs-tree.sh`, `bats tests/unit tests/contract`, and `scripts/ci/check-compose-config.sh`.
2. **Real install** (CI job `e2e`): `scripts/ci/e2e.sh` installs DevBox on a disposable runner and exercises it. Locally the same script runs inside a privileged systemd container (`scripts/ci/e2e-container.sh`).

`scripts/ci/local.sh` mirrors the workflow step for step, and `.githooks/pre-push` runs it.

**Drivers.** Desynced credentials, an ignored digest lock, empty backups and broken rotation all passed static tests. Only a real install catches regressions in sshd, UFW, routing and authentication.

**Rejected.** Static tests only. Running e2e on the developer's machine, which reconfigures users, sshd and UFW. Mocking Docker.

**Consequences.**
- The e2e needs root, a Docker daemon, network access and about 15 GB of disk.
- `CI_FAST=1 git push` skips it locally; CI always runs it.
- `contract.bats` needs the Docker CLI, and `systemd.bats` needs `systemd-analyze`.

## Monthly refresh and signed releases

**Decision.** `.github/workflows/monthly-rebuild.yml` has two jobs:

- **`refresh`:** runs `update-images.sh --apply` and `update-pins.sh --apply`, smoke-tests the result with `scripts/ci/smoke-test.sh`, and opens one pull request on `chore/monthly-refresh`. It never pushes to `main`.
- **`release`:** publishes `monthly-YYYYMMDD`, or a `vX.Y.Z` tag given when the workflow is started by hand. A monthly run happens only when `main` moved since the last release tag and `pr-validate` (including e2e) passed on that commit. It smoke-tests, builds a deterministic `devbox.tar` with its SHA256, signs it with cosign keyless into a Sigstore bundle, and publishes a GitHub release with notes from `scripts/ci/release-notes.sh`.

All actions are pinned by commit SHA.

**Drivers.** Patches arrive on a schedule but still pass review. Keyless signing leaves no long-lived key to protect, and it ties the signature to this workflow on `main`.

**Rejected.**
- Auto-merging or pushing to `main`.
- A long-lived signing key, or GPG.
- SLSA provenance: it was non-blocking and used the wrong subject format.
- A CycloneDX SBOM: it scanned the repository, not the images.

**Consequences.**
- Pull requests opened with `GITHUB_TOKEN` do not trigger `pr-validate`: close and reopen them to run the checks.
- Verification must pin both `--certificate-identity` and `--certificate-oidc-issuer`.
- A Sigstore outage means no release that month. Installing from a clone still works.

## Not included

- **Optional hardening modules** (DNAT scoping, extra fail2ban jails, generic backup skeletons): they targeted topologies DevBox never creates.
- **Laptop editor configs** that pointed at port 11434: Ollama never publishes that port, so clients go through `http://ollama.internal` with basic auth (`scripts/laptop/ollama-setup.sh`).
- **More applications** (for example AnythingLLM or Nextcloud): nothing prevents adding them as new services with contract entries. See [services/README.md](services/README.md).
