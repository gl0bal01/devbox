# Updating

How to update an installed host, how the version pins work, and how to install from a signed release.

## Update an installed host

```bash
cd ~/devbox                  # your checkout
git pull
./setup.sh --dry-run         # optional: preflight + which files under ~/docker would change
sudo ./setup.sh --yes
~/docker/start-all.sh        # setup.sh doesn't run compose; this applies the changes
```

- setup.sh is idempotent, and re-running it is also the fix path when something is wrong.
- You don't need to pass your choices again. The operator account is recorded in the root-owned `/etc/devbox/operator`. Installs older than that file have to pass `DEVBOX_USER` once, unless the user is `dev`. Everything else (SSH port, HTTPS, domain, email, GPU) is remembered in `~/.config/devbox/config.env`. An environment variable overrides the stored value, for example `sudo DEVBOX_GPU=nvidia ./setup.sh`. Keys you add to `config.env` yourself are kept.
- It keeps generated secrets, your `.env` edits, the SSH port (also on installs from before `config.env` recorded it) and the ACME state. Everything else under `~/docker/` is replaced from the repo (see [ops.md](ops.md#working-with-the-installed-stack)).
- `--no-upgrade` skips `apt-get upgrade`; required packages are still installed. `--no-dev-tools` skips the mise toolchain, Oh My Zsh, LazyVim and `.zshrc`.
- `./setup.sh --check` (no root needed) reports whether the installed runtime contract differs from the repo's copy. `make doctor` runs that check and then `status.sh`.

**Changing the SSH port** (`sudo DEVBOX_SSH_PORT=2222 ./setup.sh`): allow the new port in your provider's firewall first. setup.sh confirms sshd is listening on the new port before it replaces the old UFW rule.

## Container images

Each image is pinned twice:

1. A tag in `services/<service>/docker-compose.yml`. Traefik and Open WebUI use minor tags (`traefik:v3.7`, `open-webui:0.12`), so patch releases arrive through digest refreshes. Ollama and docker-socket-proxy publish no minor tags, so they are pinned to a patch release (`ollama/ollama:0.40.10`, `docker-socket-proxy:v0.5.0`) and only move when you bump them by hand.
2. A digest lock in `docker-compose.lock.yml`, of the form `repo:tag@sha256:<digest>`. The digest is the multi-arch index, so the same lock works on amd64 and arm64. The lock is always last in `COMPOSE_FILE`, so the stack runs exactly the locked images.

Don't edit lock files by hand. `scripts/update-images.sh` regenerates them from the tags:

```bash
scripts/update-images.sh --check     # exit 1 if any lock is behind its tag
scripts/update-images.sh --apply     # rewrite the locks
```

Both modes query the registries, so PR CI doesn't run them. Instead, `tests/contract/contract.bats` checks offline that each lock pins exactly the tag in the base file.

**Bumping a tag** (new minor or major, or a new Ollama or docker-socket-proxy patch release):

```bash
$EDITOR services/ollama-openwebui/docker-compose.yml   # change the image tag
scripts/update-images.sh --apply
bats tests/contract                                    # lock matches tag
make e2e                                               # full install + checks in a throwaway container
git commit -am "chore: bump ollama to <version>"
```

Read the upstream release notes before a major bump. Then update the host as described above.

### Rolling back

Check out the previous commit or release, then run `sudo ./setup.sh` and `~/docker/start-all.sh`. The rollback doesn't touch volumes. A newer Open WebUI may have migrated its database in a way the older version can't read. If it fails to start after a rollback, restore a backup taken before the upgrade ([ops.md](ops.md#restore)).

## Monthly automation

`.github/workflows/monthly-rebuild.yml` runs on the 1st of each month and can also be started by hand. It has two jobs:

- **refresh** runs `update-images.sh --apply` and `update-pins.sh --apply`, then smoke-tests the result with `scripts/ci/smoke-test.sh`. It opens a single PR on branch `chore/monthly-refresh` and never pushes to `main`. GitHub doesn't run `pr-validate` on PRs opened with `GITHUB_TOKEN`, so close and reopen the PR (or push to it) to run the full checks before merging.
- **release** builds a signed tarball from `main` and publishes it as release `monthly-YYYYMMDD`, after the same smoke test, and only if `pr-validate` passed on that commit. It skips the run if `main` hasn't moved since the last release tag. Named releases (`vX.Y.Z`) come from the same job: start the workflow by hand with the `tag` input (`gh workflow run monthly-rebuild.yml -f tag=v2.0.0`), which skips the refresh job. They verify exactly like monthly ones.

## Dev tools and host packages

| What | How to update |
|---|---|
| mise toolchain (node, bun, rust, uv, neovim, lazygit, lazydocker, zellij, Exegol CLI) | `mise upgrade`, run as the operator. Defaults live in `/etc/mise/config.toml`; `~/.config/mise/config.toml` overrides them. |
| AI coding CLIs | `~/docker/install-ai-dev-stack.sh --update` (`--status` lists what's installed) |
| Exegol images | `exegol update` |
| Ubuntu packages, Tailscale, mise | Automatic. setup.sh enables unattended-upgrades (`/etc/apt/apt.conf.d/20auto-upgrades`) and adds the Tailscale and mise repositories to its origins (`/etc/apt/apt.conf.d/52devbox-unattended-upgrades`). Re-running setup.sh also runs `apt-get upgrade`. |

## Trust anchors

`scripts/lib/pins.sh` holds the Tailscale and mise apt signing-key fingerprints and the Oh My Zsh commit. `scripts/update-pins.sh` checks or refreshes them:

```bash
scripts/update-pins.sh --check    # exit 1 on a key mismatch or a newer Oh My Zsh commit
scripts/update-pins.sh --apply    # move the Oh My Zsh pin to upstream HEAD
```

The script never changes key fingerprints. If a vendor rotates its key, the monthly refresh job fails, and setup.sh refuses the new key on hosts where that tool is not yet installed. Verify the new fingerprint out of band (the vendor's documentation or announcement), edit `pins.sh`, and commit.

## Install from a signed release

Each monthly release has three assets:

- `devbox.tar`: a deterministic tarball containing `services/`, `scripts/`, `setup.sh`, `ARCHITECTURE.md`, `README.md`, `LICENSE` and `docs/`
- `devbox.tar.sha256`: its checksum
- `devbox.tar.sigstore.json`: a cosign keyless signature bundle, issued to the release workflow

```bash
gh release download <tag> -R gl0bal01/devbox -p 'devbox.tar*'   # vX.Y.Z or monthly-YYYYMMDD; omit for the latest
sha256sum -c devbox.tar.sha256
cosign verify-blob devbox.tar --bundle devbox.tar.sigstore.json \
  --certificate-identity 'https://github.com/gl0bal01/devbox/.github/workflows/monthly-rebuild.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
mkdir devbox && tar -xf devbox.tar -C devbox && cd devbox && sudo ./setup.sh
```

Keep both `--certificate-identity` and `--certificate-oidc-issuer`. Without them, cosign accepts a signature from any GitHub Actions workflow. Use a current cosign release to read the bundle.

To update a release install, download and verify the newer release, extract it into a fresh directory, and run `sudo ./setup.sh` and `~/docker/start-all.sh` from there. Your settings live in `~/.config/devbox/`, not in the extracted tree.
