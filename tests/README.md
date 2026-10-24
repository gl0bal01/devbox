# Tests

The suites use [bats](https://github.com/bats-core/bats-core). Install it with `sudo apt-get install bats`.

```bash
bats tests/unit tests/contract                 # everything (CI runs exactly this)
bats tests/unit/devbox-lib.bats                # one file
bats -f "compose_file_chain" tests/unit        # tests whose name matches a regex
make test                                      # lint + docs check + bats + compose chains
```

| File | Covers | Needs |
|---|---|---|
| `tests/unit/devbox-lib.bats` | `scripts/lib/devbox-lib.sh`: secrets, atomic writes, template rendering, credentials and basic-auth hashes, `.env` editing, compose chains, the collision guard, pinned-key export, `scripts/lib/pins.sh` format | gpg, openssl, envsubst |
| `tests/unit/htb-vpn.bats` | `scripts/host/htb-vpn.sh`: PID-file tracking, tunnel replacement, `stop` signals only an openvpn process from the PID file (an impostor PID is left alone), action-first `stop`/`status` without an .ovpn path, status | nothing extra |
| `tests/contract/contract.bats` | The contract against the compose files as resolved by Compose: project and container names, `Host()` rules, backup exclusions, locks pin the base tags, hardening, published ports, socket mount, fail-closed variables, helper install-path resolution, `setup.sh --check` | Docker CLI (`docker compose config`; no daemon) |
| `tests/contract/systemd.bats` | Unit templates render against a fake install and pass `systemd-analyze verify` | systemd-analyze |

## Design

- The tests make no network calls and change nothing on the host. Each test works in its own `mktemp -d` directory and removes it in `teardown`.
- `devbox-lib.bats` sources the real library. There are no copies of functions to keep in sync.
- `htb-vpn.bats` writes fake `sudo`, `openvpn` and `ip` into a temporary directory at the front of `PATH`. The fakes record their arguments, and a sentinel file stands in for `tun0`, so no real VPN runs.
- `contract.bats` reads JSON from `docker compose config --format json` with placeholder values for `TAILSCALE_IP`, `DOMAIN` and `WEBUI_SECRET_KEY`, so assertions see what Compose sees instead of grepping YAML.

## End-to-end install

`scripts/ci/e2e.sh` installs DevBox for real and checks the result:

- the hardened host: sshd, UFW, fail2ban, Docker defaults;
- the toolchain;
- routing and basic auth through Traefik;
- credential rotation and re-run idempotency;
- digest pins and `security-check.sh`;
- a backup → wipe → restore round trip;
- the systemd units.

It reconfigures the machine it runs on, so it runs only on the CI runner (`.github/workflows/pr-validate.yml`, job `e2e`) or locally inside a throwaway privileged container:

```bash
make e2e                               # scripts/ci/e2e-container.sh, ~15 GB of free disk
KEEP=1 scripts/ci/e2e-container.sh     # keep the container for debugging
```
