# Devbox Test Suite

## Overview

Tests live under `tests/unit/` and use [bats-core](https://github.com/bats/bats-core) — the Bash Automated Testing System.

## Installing bats

**Ubuntu / Debian:**
```bash
sudo apt install bats
```

**npm (any platform):**
```bash
sudo npm install -g bats
```

**From source (latest):**
```bash
git clone https://github.com/bats-core/bats-core.git
cd bats-core && sudo ./install.sh /usr/local
```

## Running tests

```bash
# All unit tests
bats tests/unit/

# Single file
bats tests/unit/anchor-consistency.bats

# Pretty output with timing
bats --pretty tests/unit/anchor-consistency.bats

# Syntax-check all test files (no bats required)
bash -n tests/unit/*.bats
```

## Test files

| File | Tests |
|------|-------|
| `tests/unit/parse-image-line.bats` | AWK-based image-line parser (tag/digest extraction from compose YAML) |
| `tests/unit/fetch-verify.bats` | `scripts/lib/fetch-verify.sh` — SHA verification, tempfile cleanup, DEVBOX_ALLOW_UNVERIFIED |
| `tests/unit/render-env.bats` | `render_env()` from `setup.sh` — template rendering, no-overwrite, mode 0600, whitelist |
| `tests/unit/htb-vpn-pidfile.bats` | `scripts/host/htb-vpn.sh` PID file logic, escape_regex(), mocked openvpn/pkill/ip |
| `tests/unit/anchor-consistency.bats` | `scripts/ci/check-anchor-consistency.sh` — drift detection, canonical hash |

## Shared helpers

`tests/lib/test-helpers.bash` — standalone `render_env()` extracted from `setup.sh` for unit testability.

## Fixture shims

`tests/unit/fixtures/bin/` — fake `openvpn`, `ip`, `pkill`, `sudo` binaries written by `htb-vpn-pidfile.bats` setup(). These are prepended to `$PATH` only during that test file's execution.

## Design notes

- No real network calls in any test. `fetch-verify.bats` uses `file://` URLs.
- No real `openvpn` binary is invoked. Shims write their argv to a call-log.
- `anchor-consistency.bats` operates on a `cp -r` copy of `services/` in a tmpdir.
- The `render-env.bats` tests source `tests/lib/test-helpers.bash` directly, not `setup.sh`.
