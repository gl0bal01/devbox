# Contributing to DevBox

DevBox is Bash, Docker Compose YAML, templates and Bats tests. This guide covers the local setup, the checks every change must pass, and the project conventions. The design decisions are in [ARCHITECTURE.md](ARCHITECTURE.md). Read the relevant entry before you change install layout, networking, HTTPS, pinning, downloads, backups, systemd or CI.

## Development setup

On Ubuntu or Debian:

```bash
sudo apt-get install -y bats shellcheck jq gnupg openssl gettext-base systemd
# plus Docker Engine with the Compose v2 plugin, and your user in the docker group
git clone https://github.com/gl0bal01/devbox.git && cd devbox
make hooks        # pre-push runs the full local CI mirror
```

What each tool is for:

- **`bats`**: runs the test suites.
- **`shellcheck`**: runs inside `scripts/ci/lint.sh`.
- **Docker CLI**: `tests/contract/contract.bats` and `scripts/ci/check-compose-config.sh` resolve the compose files with `docker compose config`.
- **`systemd-analyze`**: `tests/contract/systemd.bats` verifies the unit templates with it.
- **gpg, openssl, envsubst**: exercised by `tests/unit/devbox-lib.bats`.

## Checks

| Command | What it runs | When |
|---|---|---|
| `make test` | lint, docs path check, bats, compose chains | While you work. Offline, takes seconds. |
| `make ci-fast` | the CI `static` job via `scripts/ci/local.sh --fast`, with a summary and log paths | Before you commit |
| `make ci` | both CI jobs, including the real install in a throwaway systemd container (`scripts/ci/e2e-container.sh`) | Before you push. The pre-push hook runs it. |

The e2e install needs about 15 GB of free disk and a privileged container. `CI_FAST=1 git push` skips it locally; CI always runs it. Never run `scripts/ci/e2e.sh` directly on a machine you care about: it creates users, moves sshd and enables UFW.

`.github/workflows/pr-validate.yml` and `scripts/ci/local.sh` must stay identical in steps and order. If you add a CI step, add it to both in the same commit.

## Making changes

- **Shell:** `#!/usr/bin/env bash`, `set -euo pipefail`, quote every expansion, `lower_snake` function names, `UPPER` constants, 4-space indents (2 for Bats and YAML, tabs in the Makefile). ShellCheck must be clean at warning level.
- **Shared logic** goes in `scripts/lib/devbox-lib.sh`, with a test in `tests/unit/devbox-lib.bats`. Keep the functions free of host side effects and pass paths explicitly.
- **Install layout, service names, hosts and backup scope** live only in `scripts/lib/devbox-contract.sh`. Bump `DEVBOX_CONTRACT_VERSION` on schema-incompatible changes.
- **setup.sh** must stay re-runnable. Every check belongs in preflight, before the first host change. Operator-owned files (`.env`, credentials, `ovh.env`) are created once and never overwritten. Setup upserts only its own keys in `config.env`.
- **Compose:** keep `no-new-privileges`, `cap_drop: ALL`, a memory limit and a healthcheck on every service. Only Traefik publishes ports, and only on `${TAILSCALE_IP:?}`. Adding a service is described in [services/README.md](services/README.md).
- **Images:** edit the tag in the base compose file, then run `scripts/update-images.sh --apply`. Never edit a lock by hand.
- **Downloads:** no `curl | sh`. Tools come from apt repositories with fingerprints pinned in `scripts/lib/pins.sh`, or from mise (`scripts/install/mise-config.toml`).
- **Secrets:** never commit rendered `.env` files, keys, `*.ovpn`, `acme.json` or anything from `.secrets/`. Secret files are written with mode 0600.

## Documentation

- `README.md` covers what DevBox does and how to use it. `ARCHITECTURE.md` covers why it works that way (Decision / Drivers / Rejected / Consequences). Do not duplicate content between them.
- `scripts/ci/check-docs-tree.sh` fails when a doc references a `services/…`, `scripts/…`, `tests/…` or workflow path that does not exist. Renaming or deleting a file means updating every doc that mentions it.
- Write plain, present-tense technical English. Leave out test counts, version banners and "last updated" lines.

## Commits and pull requests

Commit messages use `type: short description`, where type is one of `feat`, `fix`, `docs`, `refactor`, `test` or `chore`. Add a body when the reason for the change is not obvious.

```
fix: keep credentials stable across setup re-runs

Re-rendering the htpasswd hash on every run broke the stored credential.
Generate the credential once and derive the middleware from it.
```

Before you open a pull request:

- [ ] `make ci` passes (or `make ci-fast`, and say that you skipped the e2e install)
- [ ] docs and `ARCHITECTURE.md` updated if behavior or a decision changed
- [ ] no secrets, real IPs or hostnames in the diff

When you report a bug, include the output of `~/docker/diagnose.sh` (it collects no secrets), the Ubuntu and Docker versions, and the steps to reproduce.
