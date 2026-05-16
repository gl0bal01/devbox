# Devbox Architecture

This document captures the load-bearing design decisions for devbox, replacing
the per-decision ADR set under `docs/adr/` with a single readable reference.
Each section names a decision, why it was chosen, what was rejected, and the
trade-offs accepted.

## Trust Model

**Decision.** Devbox uses a network-centric trust model, not local privilege separation.

The security boundary is **Tailscale ACL + SSH key auth + UFW default-deny**. Inside
that boundary, the `dev` user is in the `docker` group, which grants root-equivalent
access to the host (the docker socket can bind-mount `/` as root). This is an
intentional, documented fact, not a flaw.

**Drivers.** Forcing rootless docker would block many pentest tools and add 30+ minutes
of operational friction per install. Tailscale + SSH key auth is a stronger boundary
than sudoers theater because it actually prevents reach.

**Rejected.** Rootless docker (operational cost too high); sudoers-only "least privilege"
(false security — docker socket bypasses it); userns-remap (complicates volume mounts,
incompatible with several pentest tools).

**Consequences.** SSH key compromise → full root. Tailscale account compromise → full
LAN access. Local privilege escalation is out of scope. `docs/security.md` documents
this explicitly.

## Install Layout

**Decision.** `setup.sh` is a host bootstrapper. The source of truth is the git repo
(`services/`, `scripts/host/`, `scripts/lib/`, `scripts/systemd/`); `setup.sh` rsyncs
into `${HOME}/docker/`, renders `.template` files, writes `.devbox-marker` and
`~/.config/devbox/config.env`, and exits. Helpers run from `${HOME}/docker/`.

**Drivers.** v3 setup.sh was 2072 lines of heredocs and inline configuration that
silently diverged from the tracked files. Moving everything to tracked files makes
diff review and CI possible. The bootstrapper shrank to <1000 lines.

**Rejected.** Symlinks from `${HOME}/docker/` back into the repo (operator confusion,
permission issues); install-script generates everything from heredocs (the v2 design,
unmaintainable).

**Consequences.** Operators must NOT hand-edit `${HOME}/docker/` — `setup.sh` overwrites
it on re-run. Hand edits are recoverable from `~/.local/share/devbox/backups/` snapshots
taken before each rsync (intentional design). The collision guard in `setup.sh` refuses
to install into a non-devbox `${HOME}/docker/` tree (allowlist + `.devbox-marker` for
upgrade-in-place).

## Runtime Contract

**Decision.** `scripts/lib/devbox-contract.sh` is the canonical source of install layout,
service identities, container names, Traefik hosts, named volumes, backup targets, and
the pinned alpine digest. Setup.sh installs a copy into `${DEVBOX_HOME}/lib/`; helpers
source the installed copy and consume contract accessors (`devbox_get`,
`devbox_compose_chain_for`, `devbox_compose_chain_key`, `devbox_contract_warn_drift`).

The installed copy is the runtime authority. Helpers print a non-blocking WARN if the
repo copy differs (drift detected by `cmp -s`).

**Drivers.** Pre-contract, `setup.sh` installed services into `~/docker/<svc>` but
helpers iterated `~/docker/devbox/services/<svc>`; var names disagreed (`ENABLE_HTTPS`
vs `HTTPS_ENABLED`). Every fresh install silently skipped every service. The contract
fixes the class of bug by giving everyone one shape to read from.

**Rejected.** YAML config + shell parser (adds parser dependency); duplicate constants
across setup.sh + each helper (the original drift source); environment-variable-only
(no canonical declaration site).

**Consequences.** Helpers refuse to run without the installed contract. `setup.sh` is
the only sync path between repo and installed copies. Bats contract tests pin the
shape: every `Host(*.internal)` literal has a router; every named volume is backed up;
every container_name matches `security-check.sh`; emitted config.env keys ⊇
helper-read keys. Contract version bumps (currently v2) signal schema changes.

## HTTPS via Compose Override (Tailscale-Bound)

**Decision.** HTTPS support is an opt-in Compose override file
(`services/<svc>/docker-compose.https.yml`), enabled by `ENABLE_HTTPS=true` in
`~/.config/devbox/config.env`. The override adds `tls=true` plus
`certresolver=letsencrypt` per router and binds port 443 to `${TAILSCALE_IP}` —
**no public 0.0.0.0 bind**. Both HTTP (port 80) and HTTPS (port 443) are Tailscale-only.
Certificates come from Let's Encrypt via OVH DNS-01 (credentials in
`~/.config/devbox/ovh.env`, never tracked).

**Drivers.** Want TLS for clients that demand HTTPS without exposing the listener to
the public internet. DNS-01 avoids requiring port 80 reachable from the public
internet.

**Rejected.** Single compose file with TLS toggle (couples concerns); ACME HTTP-01
challenge (would require public port 80); self-signed certs (browser friction).

**Consequences.** Operators on the Tailnet hit `https://ai.internal` (and
`https://ai.${DOMAIN}`) and get a valid public cert. Off-Tailnet clients cannot reach
the listener at all. OVH credentials live outside the repo at `~/.config/devbox/ovh.env`
(mode 0600). README and `docs/updating.md` document this.

## Image Pinning + Digest Lockfiles

**Decision.** Base `services/*/docker-compose.yml` files pin images by exact minor tag
(`traefik:v3.2`, `ollama/ollama:0.5.13`). A generated `docker-compose.lock.yml` per
service pins by sha256 digest (`traefik@sha256:...`). Setup.sh emits compose chains as
`docker-compose.yml[:docker-compose.https.yml][:docker-compose.lock.yml]` so the
lockfile is always loaded when present. `scripts/update-images.sh` (two-pass per
Critic #2) refreshes lockfiles; CI gates on `update-images.sh --check`.

**Drivers.** Reproducibility: a tag can move but a digest cannot. Trust but verify:
operators see what's actually running.

**Rejected.** Tag-only (mutable, no reproducibility); digest-only in base file (loses
auto-patch updates); hand-maintained lock files (drift).

**Consequences.** Weekly CI runs `update-images.sh --apply` and produces a smoke-tested
weekly-* release. Operators on `main` get the latest lockfile on every weekly. Major
version bumps (e.g., `v3.2 → v4.0`) are manual base-file edits.

## Tag Strategy: Minor-Pinned, Operator-Bumped Majors

**Decision.** Image tags in the base compose file are minor-pinned (`traefik:v3.2`).
Weekly CI runs `--apply` and refreshes digests within the minor — operators get patch
fixes automatically. Major version bumps are manual: operator edits the tag, runs
`--apply`, smoke-tests, commits.

**Drivers.** Patches usually contain security fixes (want them automatic). Majors
usually break things (require manual review).

**Rejected.** Tag-by-major-only (miss patches); tag-by-digest-only in base (lose
auto-refresh signal); fully automatic major bumps (breaking changes ship un-reviewed).

**Consequences.** New minor releases require operator action (intentional). The
Operator inspects available majors manually via `docker manifest inspect <image>:<tag>` or upstream release notes.

## Alpine Backup Image Refresh

**Decision.** `scripts/lib/devbox-contract.sh` pins `ALPINE_BACKUP_IMAGE=alpine@sha256:...`
for `backup.sh`'s named-volume export. `.github/workflows/weekly-rebuild.yml` includes
an `alpine-digest-check` job that resolves the upstream `alpine:3.21` manifest, compares
to the contract, and on drift opens a PR via `peter-evans/create-pull-request@v6` —
never mutates `main` directly.

**Drivers.** Backups must be reproducible; pinning by tag-only would silently change.
Auto-PR keeps the operator in the loop without daily-busywork.

**Rejected.** Auto-commit to main (no review); never refresh (digest goes stale, OS
patches missed); pin in setup.sh instead of contract (forces re-render on every bump).

**Consequences.** First weekly run after a digest change opens a PR. Operator reviews
the diff (single-line digest swap), runs the manual `docker manifest inspect` to
confirm, merges. Workflow injection-safe: all manifest output flows through env vars
to `run:` blocks; PR body comes from `body-path:` file, not inline `body:`.

## Traefik Security Middleware

**Decision.** Security middleware (HSTS, frame-deny, CSP, rate-limit, IP allowlist
constrained to Tailscale CGNAT IPv4 + IPv6 ULA + loopback) is wired at the entrypoint
level in `traefik.yml`, not per-router. Files live in
`services/traefik/dynamic/middlewares-*.yml`. The HTTPS-only HSTS middleware
(`middlewares-https.yml`) is rendered only when `ENABLE_HTTPS=true`.

**Drivers.** Per-router middleware is repetitive and easy to forget on a new router.
Entrypoint-level wiring catches every router behind the entrypoint by default.

**Rejected.** Per-router labels (forgettable); global middleware in `traefik.yml`
without a file provider split (mixes static + dynamic concerns).

**Consequences.** Adding a new service requires only `traefik.enable=true` + router
labels; middleware is automatic. Disabling a middleware globally is one file edit.

## Per-File `x-logging` Anchor

**Decision.** Each `services/*/docker-compose.yml` includes its own 4-line `x-logging`
anchor. CI (`scripts/ci/check-anchor-consistency.sh`) sha256s the anchor block and
fails if any file diverges.

**Drivers.** YAML anchors are per-file; cross-file inclusion does not work
(empirically tested). Per-file duplication with CI drift detection is the only
spec-compliant approach.

**Rejected.** External logging library; YAML merge keys (broken across Compose
versions); Compose extends: (deprecated for logging).

**Consequences.** Logging config changes must land in one commit touching every
compose file. CI keeps this honest.

## Verified Downloads

**Decision.** Every `curl ... | sh` style network install is routed through
`scripts/lib/fetch-verify.sh` with the expected sha256 pinned in
`scripts/lib/download-manifest.sh`. `DEVBOX_ALLOW_UNVERIFIED=1` is the named
emergency override (loud warning).

**Drivers.** Supply-chain attack surface. Without verification, the security boundary
is "trust whatever happened to be at this URL today."

**Rejected.** Distro packages only (some tools aren't packaged); checked-in binaries
(license + size); GPG-only (most upstreams don't sign in a verifiable way).

**Consequences.** Operators see explicit verification on every download. SHA bumps
require commit + review. The `--unverified` override prints a loud banner so the
operator cannot pretend it didn't happen.

## Release Tarball: Cosign Keyless + SLSA + SBOM

**Decision.** Weekly CI builds a deterministic `devbox.tar`, signs with cosign keyless
(GitHub OIDC + Sigstore Rekor), generates a CycloneDX SBOM, attaches a SLSA Build L3
provenance attestation, and publishes via `gh release create`. Operators install via
the tarball after `cosign verify-blob` (with both `--certificate-identity` AND
`--certificate-oidc-issuer`) and optional `slsa-verifier`.

**Drivers.** Production installs need an immutable, verifiable artifact. Cosign
keyless removes the long-lived signing key footgun.

**Rejected.** Long-lived cosign key (key management burden); GPG-signed tarball
(needs to verify the public key out-of-band); no signing (downgrade risk for any
operator who skips verification).

**Consequences.** First weekly run after each main commit produces a signed bundle.
`docs/updating.md` documents the verify sequence. The tarball bundles `services/`,
`scripts/`, `setup.sh`, `docs/`, `README.md`, `LICENSE` — self-contained install.

## Snapshot-Only Recovery (No Auto-Rollback)

**Decision.** `setup.sh` snapshots `~/docker/` and `~/.config/devbox/` into
`~/.local/share/devbox/backups/<timestamp>/` before any destructive operation (rsync,
sudoers edit, template render). Recovery is operator-driven: pick a snapshot, copy
back, restart. There is no auto-rollback.

**Drivers.** Auto-rollback requires accurate failure detection. False positives cause
worse incidents than the original failure. Snapshots + operator decision is more
resilient.

**Rejected.** Git-managed runtime tree (mixes operator state with code state);
automatic rollback on health-check fail (false positives during slow upstream pulls);
no recovery story (hostile to operators).

**Consequences.** Operators must learn the snapshot directory layout. `docs/ops.md`
documents the recovery procedure with concrete commands. `backup.sh` (separate from
snapshots) exports named volumes via `docker run -v <vol>:/data alpine@sha256:... tar`.

## Systemd Integration (Single Stack Unit + Daily Backup Timer)

**Decision.** `make install-systemd` (or `${HOME}/docker/install-systemd.sh` directly)
renders three units from templates under `${HOME}/docker/systemd/` and installs them
into `/etc/systemd/system/`:

- `devbox.service` — `Type=oneshot`, `RemainAfterExit=yes`, `ExecStart=${DEVBOX_HOME}/start-all.sh`,
  `ExecStop=${DEVBOX_HOME}/stop-all.sh`.
- `devbox-backup.service` — `Type=oneshot`, `Requires=devbox.service`,
  `Nice=10 IOSchedulingClass=idle`, runs `backup.sh`.
- `devbox-backup.timer` — `OnCalendar=daily Persistent=true RandomizedDelaySec=1800`.

The installer enables `devbox.service` + `devbox-backup.timer` (NOT the backup
service directly — timer-driven) but does NOT auto-start; operator decides.

**Drivers.** Per-container systemd units add no value over Compose's `restart: unless-stopped`.
A single oneshot stack unit gives operators `systemctl start devbox` + boot-time
automation without doubling the failure modes.

**Rejected.** Per-service systemd unit (couples to compose internals, double restart
policy); systemd Compose plugin (Compose-managed bare-systemd path is enough); no
systemd at all (operators want boot-time start + scheduled backup).

**Consequences.** Bats `tests/contract/systemd.bats` exercises `systemd-analyze verify`
against each rendered template + asserts they reference the contract's `DEVBOX_HOME`
and `DEVBOX_USER`.

## Ollama Basic Auth (Per-Install Credential + Rotation)

**Decision.** `setup.sh` generates a per-install 32-char password for the
`ollama-auth@file` middleware. The htpasswd hash lives in
`${DEVBOX_HOME}/traefik/dynamic/ollama-auth.yml` (mode 0600); the plaintext lives in
`${DEVBOX_HOME}/.secrets/ollama-auth.txt` (mode 0600). External clients of
`http://ollama.internal` (Tailscale-only) authenticate with this credential.

Open WebUI talks to Ollama on the internal Compose network
(`http://ollama:11434`, no auth) and is unaffected by rotation.
`scripts/host/rotate-ollama-auth.sh` regenerates both files and runtime-checks
Open WebUI's `OLLAMA_BASE_URL` to catch misconfigurations.

**Drivers.** Want unauthenticated internal access (Open WebUI just works) but
authenticated external access (any Tailscale client needs the credential).

**Rejected.** Shared static credential (operational risk on disclosure); no auth on
the external route (Tailscale alone is the boundary, but auth-in-depth is cheap);
auth at the Compose-network level (would break Open WebUI).

**Consequences.** Operator retrieves the credential from
`${DEVBOX_HOME}/.secrets/ollama-auth.txt`. Rotation requires no Open WebUI changes
unless the operator manually pointed `OLLAMA_BASE_URL` at the external host (the
rotation script warns when it sees this).

## CI: pr-validate + weekly-rebuild

**Decision.** `.github/workflows/pr-validate.yml` runs on every PR: lint
(shellcheck + bash -n + 55 unit bats), compose-config validate (HTTP + HTTPS),
anchor consistency, docs↔tree consistency, digest lockfile freshness. Docker Hub login
is conditional (`if: env.DOCKERHUB_USERNAME != ''`) so forks don't fail.

`.github/workflows/weekly-rebuild.yml` runs Monday 06:00 UTC (or via
`workflow_dispatch`): same lint + compose-config + anchor + smoke test + lockfile
refresh + deterministic tarball + cosign signing + SBOM + SLSA + GitHub release. A
separate `alpine-digest-check` job opens an auto-PR on alpine digest drift.

**Drivers.** Catch drift early; produce a verifiable weekly artifact; let forks
contribute without secret setup.

**Rejected.** Single monolithic workflow (hard to retry one step); no fork support
(community-hostile); no auto-PR for alpine (digest goes stale silently).

**Consequences.** Every PR runs the full contract test suite (35 contract bats + 55
unit bats). Weekly tag is the reproducible install path. Alpine refresh PRs require
operator merge.

## Contract Bats Test Suite

**Decision.** `tests/contract/contract.bats` (24 tests) + `tests/contract/systemd.bats`
(11 tests) form the install-contract regression suite. Tests run against the repo
files, not a live install — they don't require docker except for two explicit
network-gated assertions (`docker manifest inspect ollama/ollama:0.5.13` and
`update-images.sh --check`).

Coverage: contract structure, helper-read vars ⊆ setup-emitted keys, every
documented `Host(*.internal)` has a router, named volumes ⊆ backup targets,
container names ⊆ security-check references, ollama auth wiring, HTTPS overlay
shape, install-marker shape, dry-install fixture equality, systemd rendering +
analyze-verify, lockfile sync.

**Drivers.** v3 shipped with 55 unit bats but zero install-contract tests. Drift
caught only by operator first-install pain. Adding contract tests at PR-validate
gate prevents the same class of regression from re-entering.

**Rejected.** Live-install integration tests (slow, brittle, require root); unit
tests only (don't catch drift); manual review (proven insufficient).

**Consequences.** Every PR runs the 35 contract tests. Schema changes require test
updates (contract v2 bump updated test 7 for the printf-based emission + dynamic
key naming).

## Skipped / Deferred

- **AnythingLLM, Nextcloud** — initially scoped, dropped from v1.0.0 to keep the
  base contract small. Either can be added later via a new `services/<svc>/` + a
  contract entry + a Bats test. No design constraint blocks reintroduction.
- **--dry-run integration with a live diff against an existing install** — current
  `--dry-run` prints planned actions but does not diff binary-level. Adequate for
  P0; richer diffing deferred.
- **`DEVBOX_USER` migration semantics** — when contract version bumps from 2 to 3,
  `setup.sh --check` will need to detect old config.env shape and emit a clear
  migration message. Deferred until a real schema change lands.

## References

- `scripts/lib/devbox-contract.sh` — canonical contract.
- `tests/contract/` — assertions that pin the contract shape.
- `docs/security.md` — trust model + threat boundaries.
- `docs/ops.md` — incident response + backup/restore procedures.
- `docs/updating.md` — image digest refresh + signed-tarball install + alpine refresh.
- `services/README.md` — Compose layout, rendering table, anchor pattern.
- `README.md` — quick start + architecture diagram.
