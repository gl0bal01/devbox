# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

DevBox: a Bash + Docker Compose host bootstrapper for Ubuntu 24.04. There is no compiled code and no package manager. The repo is shell scripts, Compose YAML, templates and Bats tests. Toolchain: Bash 5+, Docker with the Compose v2 plugin, ShellCheck, bats (install with apt), jq, gpg, openssl, envsubst (gettext-base) and systemd-analyze.

## Commands

```bash
make test                     # static CI job: lint + docs-check + bats + compose-check
make ci-fast                  # scripts/ci/local.sh --fast: static job with a pass/fail summary and log paths
make ci                       # full CI mirror, including the e2e install in a throwaway container (pre-push runs this)
make e2e                      # only the e2e install (scripts/ci/e2e-container.sh; needs ~15 GB of disk)
make hooks                    # enable .githooks/pre-push (CI_FAST=1 git push skips e2e)
bats tests/unit tests/contract                        # all bats tests
bats tests/unit/devbox-lib.bats                       # one file
bats -f "env_set" tests/unit/devbox-lib.bats          # tests whose name matches a regex
scripts/ci/check-docs-tree.sh                         # doc path references must exist
scripts/update-images.sh --apply|--check              # regenerate/check digest locks (queries registries)
scripts/update-pins.sh --apply|--check                # check vendor key fingerprints, bump the Oh My Zsh commit (network)
./setup.sh --dry-run                                  # preflight + plan + rsync diff, no root, no changes
./setup.sh --check                                    # installed contract vs repo, no root
```

`make start|stop|status|backup|security-check|rotate-ollama-auth|install-systemd` need an installed stack (`~/docker/lib/.devbox-marker`). `make doctor` runs `setup.sh --check` and then `status.sh`.

CI: `.github/workflows/pr-validate.yml` has two jobs. `static` runs `scripts/ci/lint.sh`, `scripts/ci/check-docs-tree.sh`, `bats tests/unit tests/contract` and `scripts/ci/check-compose-config.sh`. `e2e` runs `scripts/ci/e2e.sh`, a real install on the runner. `scripts/ci/local.sh` mirrors both jobs 1:1: when you add a CI step, add it there in the same commit. `.github/workflows/monthly-rebuild.yml` opens one refresh PR (digest locks + pins, smoke-tested) and publishes a cosign-signed release tarball. It never pushes to `main`. PR CI never queries registries.

## Architecture: repo vs installed tree

The repo is the source. `~/docker/` is the installed runtime. `setup.sh` converges the host in phases:

1. packages
2. vendor apt repos
3. Tailscale
4. operator user
5. Docker defaults
6. mise toolchain
7. stack
8. sshd/fail2ban/UFW

In the stack phase, it rsyncs `services/<svc>/`, `scripts/host/*.sh`, `scripts/lib/devbox-contract.sh`, `scripts/lib/devbox-lib.sh` and `scripts/systemd/*.template` into `~/docker/`. Then it renders templates and writes `~/.config/devbox/config.env` and `~/docker/lib/.devbox-marker`. Helpers run from `~/docker/`, never from the repo. They compute `DEVBOX_HOME` from their own location, because `sudo` sets `HOME=/root`, and `contract.bats` enforces this.

Installed files fall into three classes. Keep them distinct:

- **Tracked:** mirrored with `rsync --delete` on every run. Excluded from the mirror: dotfiles, `ovh.env`, `letsencrypt/`, `logs/`, `dynamic/*-auth.yml`, `*.template`.
- **Operator-owned, created once:** each service `.env` (`render_once`), the credentials in `~/docker/.secrets/` (`ensure_credential`), `ovh.env`. ACME state lives in the Traefik-owned named volume `traefik_letsencrypt`, not on the host.
- **Derived, re-rendered every run:**
  - `dynamic/dashboard-auth.yml` and `dynamic/ollama-auth.yml` (`render_basic_auth`, no `$$` escaping). They are mode 0640, and Traefik reads them via `group_add: ${DEVBOX_GID:?}`, because with `cap_drop: ALL` root cannot read operator-owned 0600 files.
  - `traefik.yml` in HTTPS mode.
  - The setup-managed `.env` keys: `COMPOSE_FILE`, `TAILSCALE_IP`, `DEVBOX_GID`, `DOMAIN`, and the `OLLAMA_CPUS` default.
  - Setup's own keys in `config.env`, upserted with `env_set`; operator keys such as `BACKUP_GPG_RECIPIENT` are preserved.

The operator is `DEVBOX_USER`, else the name recorded in the root-owned `/etc/devbox/operator` (trusted only when owned by root with mode 644), else `dev`. Never infer it from user-writable paths.

Preflight is read-only and collects every error before the first change. SSH lockdown runs last. The drop-in is `00-devbox.conf`, so it wins over cloud-init's `50-`. It is checked with `sshd -t` and `sshd -T`, sshd must be listening on the new port before UFW is touched, and any failure rolls back. Root never sources operator-owned files: `config.env` and `ovh.env` are parsed with `sed` (`devbox_config_get`, `env_get`).

### Runtime contract and shared library

`scripts/lib/devbox-contract.sh` declares the service list (dependency order), container names, Traefik hosts, install paths and backup scope. Its accessors are `devbox_get <svc> CONTAINERS|HOST` and `devbox_config_get <KEY> [default]`. It is bash-only (`DEVBOX_SERVICES` is an array) and stays declarative. Bump `DEVBOX_CONTRACT_VERSION` on schema-incompatible changes. The installed copy is the runtime authority, and `setup.sh --check` reports drift.

`scripts/lib/devbox-lib.sh` holds the shared functions: `write_atomic`, `render_template`, `render_once`, credentials, `env_set`/`env_default`/`env_unset`, `compose_file_chain`, `rsync_install`, `collision_guard`, `gpg_export_pinned`, `apt_add_repo`. `setup.sh` and the helpers source it, and `tests/unit/devbox-lib.bats` tests it directly. Keep the pure functions free of host mutation and pass paths explicitly.

Adding a service means all of the following:

- a `DEVBOX_SERVICES` entry, plus `DEVBOX_CONTAINERS_<svc>` and `DEVBOX_HOST_<svc>` (dashes become underscores);
- `services/<svc>/docker-compose.yml` with `name: <svc>`, a `container_name` for each container, `Host()` rules equal to the contract hosts, and the hardening (`no-new-privileges`, `cap_drop: ALL`, `mem_limit`, healthcheck);
- a lock generated with `scripts/update-images.sh --apply`.

`tests/contract/contract.bats` enforces all of this. See `services/README.md`.

### Compose chain, binding, HTTPS

Each service's `.env` sets native `COMPOSE_FILE=docker-compose.yml[:docker-compose.https.yml][:docker-compose.gpu.yml]:docker-compose.lock.yml` (`compose_file_chain`). Plain `docker compose` in the directory therefore always uses the full chain, and the digest lock always applies. Top-level `name:` pins project and volume names.

Only Traefik publishes ports, and only on `${TAILSCALE_IP:?}`. Never introduce a `0.0.0.0` bind or a `${VAR:-}` default for a bind address or secret: Docker-published ports bypass UFW. `check-compose-config.sh` validates every HTTP/HTTPS/GPU chain and fails on wildcard binds.

HTTPS is an opt-in overlay (`ENABLE_HTTPS`, `DEVBOX_DOMAIN`, `DEVBOX_EMAIL`, OVH DNS-01 credentials in `~/.config/devbox/ovh.env`), still bound to the Tailscale IP. The entrypoint middlewares (security headers + Tailscale allowlist; HSTS on `websecure`) apply to every router.

### Images and trust

Base files pin minor tags (`traefik:v3.7`, `open-webui:0.12`). Images without minor tags are patch-pinned and bumped by hand: `ollama/ollama:0.40.10` and `tecnativa/docker-socket-proxy:v0.5.0`. Locks (`repo:tag@sha256:<index digest>`) come only from `scripts/update-images.sh --apply`; never edit them by hand. `contract.bats` checks offline that each lock pins exactly the base tags.

There is no `curl | sh` anywhere. Tailscale and mise come from vendor apt repos whose signing-key fingerprints are pinned in `scripts/lib/pins.sh` (`apt_add_repo` → `gpg_export_pinned`). Dev tools come from `scripts/install/mise-config.toml` (explicit `aqua:` backends so mise verifies checksums and attestations; `pypi:exegol`). AI CLIs come from `scripts/host/install-ai-dev-stack.sh`, also through mise. Oh My Zsh is pinned by commit. `update-pins.sh` never changes fingerprints automatically.

### Tests

- `tests/unit/devbox-lib.bats`: the library functions in temp dirs. The gpg key test generates throwaway keys.
- `tests/unit/htb-vpn.bats`: `scripts/host/htb-vpn.sh` against fake `sudo`/`openvpn`/`ip` written into a temp `PATH`. A `tun0` sentinel file stands in for the interface. It covers the PID file, refusing to signal a non-openvpn PID, and the action-first `stop`/`status` form.
- `tests/contract/contract.bats`: compares the contract, the compose files as resolved by `docker compose config --format json` (needs the Docker CLI), the locks and the helpers.
- `tests/contract/systemd.bats`: renders the unit templates and runs `systemd-analyze verify`.
- `scripts/ci/e2e.sh`: a real install, routing, auth, rotation, re-run idempotency, backup/restore and systemd. It reconfigures the host, so run it only through `make e2e` or in CI.

### Docs are CI-checked

`scripts/ci/check-docs-tree.sh` scans `README.md`, `ARCHITECTURE.md`, `CONTRIBUTING.md`, `CLAUDE.md`, `services/README.md`, `tests/README.md`, `scripts/laptop/README.md` and `docs/*.md`. It fails on any `services/…`, `scripts/…`, `tests/…` or `.github/workflows/*.yml` path that does not exist. Paths containing `<` or `*` are skipped as placeholders. When you rename or delete a file, update every doc that mentions it.

## Conventions

- `#!/usr/bin/env bash`, `set -euo pipefail`, quoted expansions, `lower_snake` functions, `UPPER` constants. Indent shell with 4 spaces, Bats and YAML with 2, Makefile with tabs. ShellCheck runs at warning level and above, excluding only SC1091.
- Secrets: rendered `.env` files, `ovh.env`, `acme.json`, `.secrets/`, `*.ovpn` and keys are gitignored. Only `.env.template` and `.env.example` are tracked. Secret files are mode 0600 (the auth middlewares 0640); write them with `write_atomic`.
- Compose services keep `no-new-privileges`, `cap_drop: ALL`, healthchecks and resource limits. No per-file logging blocks: log rotation comes from `/etc/docker/daemon.json`.
- Commits: `type: short description` (`feat|fix|docs|refactor|test|chore`).
- `ARCHITECTURE.md` records the load-bearing decisions (Decision / Drivers / Rejected / Consequences). Read the relevant entry before you change install layout, networking, HTTPS, pinning, downloads, backups, systemd or CI, and update it when the decision changes.
