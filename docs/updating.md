# Updating Images and Verifying Signatures

This guide explains how to refresh image digests, verify cosign signatures, and understand the three installation modes.

## Install from a signed release tarball

The recommended production install path is the signed weekly release tarball, not a `git clone`. Every tarball is:

- **Signed** with cosign keyless (GitHub OIDC, Sigstore Rekor transparency log)
- **Digest-attested** with a `sha256sum`-verifiable `.sha256` file
- **SLSA provenance** attached as an in-toto attestation (SLSA Build L3)
- **SBOM** generated from the locked image set (CycloneDX JSON)
- **Immutable** per weekly tag — the tarball content is frozen at build time

The git-clone path (`git clone ... && ./setup.sh`) is fine for development and contribution. For any persistent or production deployment, prefer the tarball so you get the full verification chain.

### Download the latest weekly release

```bash
# Resolve the latest weekly-* tag
TAG="$(gh release list --repo gl0bal01/devbox --json tagName,createdAt \
      --jq 'sort_by(.createdAt) | last | .tagName')"

# Download tarball + all attestation files
gh release download "$TAG" --repo gl0bal01/devbox \
  -p 'devbox.tar' -p 'devbox.tar.sha256' -p 'devbox.tar.sig' \
  -p 'devbox.tar.pem' -p 'sbom.cdx.json' -p 'devbox.tar.intoto.jsonl'
```

### Verify before extracting

**Step 1 — SHA256 integrity check:**

```bash
sha256sum -c devbox.tar.sha256
# Expected output: devbox.tar: OK
```

**Step 2 — cosign keyless signature verification:**

```bash
# Install cosign if needed: https://docs.sigstore.dev/system_config/installation/
cosign verify-blob devbox.tar \
  --signature devbox.tar.sig \
  --certificate devbox.tar.pem \
  --certificate-identity 'https://github.com/gl0bal01/devbox/.github/workflows/weekly-rebuild.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
# Expected output: Verified OK
```

Both `--certificate-identity` and `--certificate-oidc-issuer` are required — omitting either would accept any GitHub Actions workflow as a valid signer.

**Step 3 — SLSA provenance verification (optional, recommended for compliance):**

```bash
# Install slsa-verifier: https://github.com/slsa-framework/slsa-verifier
slsa-verifier verify-artifact devbox.tar \
  --provenance-path devbox.tar.intoto.jsonl \
  --source-uri github.com/gl0bal01/devbox \
  --source-tag "$TAG"
# Expected output: PASSED: SLSA verification passed
```

### Extract and run

```bash
mkdir "devbox-${TAG}"
tar -xf devbox.tar -C "devbox-${TAG}"
cd "devbox-${TAG}"

# Review what setup.sh will do (no root required for dry-run):
./setup.sh --dry-run

# Install:
sudo ./setup.sh
```

The tarball bundles `services/`, `scripts/`, `setup.sh`, `README.md`, `LICENSE`, and `docs/` — everything needed for a self-contained install with no network access to the repo.

---

## Image Digest Refresh

Devbox uses minor-pinned tags (e.g., `traefik:v3.2`) with SHA digest locking for reproducibility. The `update-images.sh` script refreshes digests within the pinned minor version.

### Check for Updates (Dry-Run)

```bash
cd ~/docker/devbox  # Or wherever you cloned the repo

# Check if any digests have changed
./scripts/update-images.sh --check
echo "Exit code: $?"
```

Exit code 0 means the committed lockfiles match the latest resolved digests. Exit code 1 means updates are available.

### Review Proposed Changes

```bash
# See exactly what would change
git diff HEAD -- services/*/docker-compose.lock.yml

# Or, after running --check, see the new lockfile:
cat /tmp/update-check-output.lock.yml | diff -u services/traefik/docker-compose.lock.yml - | head -50
```

### Apply Updates

```bash
# Refresh all image digests within pinned minors
./scripts/update-images.sh --apply

# Review the changes
git diff services/

# If satisfied, commit
git add services/
git commit -m "Refresh image digests ($(date +%Y-%m-%d))"

# If something looks wrong, revert
git checkout HEAD -- services/
```

## Major Version Bumps

Minor-pinned tags (e.g., `traefik:v3.2`) pull the latest patch within the minor. Major version bumps (`v3 → v4`) are manual edits.

### Preview Available Major Versions

```bash
./scripts/update-images.sh --preview-majors

# Output:
# traefik:
#   Current: v3.2 (latest patch: v3.2.5)
#   Available majors: v4.0, v4.1 (latest: v4.1.3)
#   Recommended: v4.1 (latest stable)
#
# ollama:
#   Current: 0.1 (latest patch: 0.1.47)
#   Available majors: none (0.x is latest)
```

### Bump a Major Version

1. **Edit the base compose file:**
   ```bash
   # Edit services/traefik/docker-compose.yml
   # Change: image: traefik:v3.2
   # To:     image: traefik:v4.1
   ```

2. **Refresh digests to resolve the new version:**
   ```bash
   ./scripts/update-images.sh --apply
   ```

3. **Test the new version locally (if possible):**
   ```bash
   docker compose -f services/traefik/docker-compose.yml \
                  -f services/traefik/docker-compose.lock.yml config | grep "image: traefik"
   
   # Or spin up a test environment:
   docker compose up --no-start  # Create containers without starting
   docker compose up traefik      # Start one service to test
   docker compose logs traefik    # Watch for errors
   docker compose down            # Cleanup
   ```

4. **Commit the changes:**
   ```bash
   git add services/
   git commit -m "Bump traefik to v4.1 (breaking changes noted in v4.0 changelog)"
   ```

## Installation Modes

Devbox supports three installation modes, with increasing trust requirements and reproducibility.

### Mode 1: `latest` (Development Only)

Install from the latest commit on the main branch:

```bash
git clone https://github.com/organization/devbox.git
cd devbox
./setup.sh
```

**What you get:**
- Pulls the latest code from main
- Uses whatever image digests are currently committed
- No signature verification
- No smoke test
- **NOT RECOMMENDED for production**

**When to use:**
- Development and testing
- Contributing to devbox itself
- Rapid iteration

**Risk:**
- Digests may not have been smoke-tested before merge
- No provenance information
- Bleeding-edge (possible regressions)

### Mode 2: `weekly-YYYYMMDD` (Recommended for Production)

Install from a tagged weekly release:

```bash
# List available weekly releases
git tag | grep weekly- | sort

# Checkout a specific weekly tag (e.g., weekly-20260413)
git checkout weekly-20260413
./setup.sh
```

**What you get:**
- Digests have been:
  - Resolved from minor-pinned tags by CI
  - Smoke-tested (all services start and pass health checks)
  - Signed with cosign keyless (GitHub OIDC identity)
  - Attested with SBOM (dependencies list)
  - Attested with SLSA provenance (build environment)
- Git tag exists (immutable reference)
- cosign signature in the GitHub release

**When to use:**
- **Production deployments** (recommended)
- Persistent installs
- Any case where reproducibility matters

**Risk:**
- One week behind latest (by design, allows time for issues to surface)
- If the weekly release is bad, rollback to the prior week's tag

### Mode 3: `@sha256:<digest>` (Most Paranoid)

Pin the release artifact by SHA256:

```bash
# Find the SHA256 in the GitHub release page
# (Or compute: sha256sum devbox.tar.gz)

DEVBOX_SHA256="abc123def456..."
curl -fsSL https://github.com/organization/devbox/releases/download/weekly-20260413/devbox.tar.gz \
  -o devbox.tar.gz

# Verify the SHA
echo "$DEVBOX_SHA256  devbox.tar.gz" | sha256sum -c

# Extract and install
tar -xzf devbox.tar.gz
cd devbox
./setup.sh
```

**What you get:**
- Exact artifact verification by cryptographic hash
- Same guarantees as Mode 2 (weekly tag)
- Immutable reference (SHA is the artifact's permanent identity)

**When to use:**
- Maximum reproducibility
- Compliance requirements (e.g., financial, healthcare)
- Offline verification (compare SHA manually)

**Risk:**
- Requires manually tracking SHAs (harder to automate updates)
- Still depends on GitHub release integrity

## Verifying Cosign Signatures

For `weekly-YYYYMMDD` releases, cosign signatures are available in the GitHub release.

### Verify the Release Artifact

```bash
# Download the release and signature
RELEASE_TAG="weekly-20260413"
curl -fsSL https://github.com/organization/devbox/releases/download/${RELEASE_TAG}/devbox.tar.gz \
  -o devbox.tar.gz
curl -fsSL https://github.com/organization/devbox/releases/download/${RELEASE_TAG}/devbox.tar.gz.sig \
  -o devbox.tar.gz.sig

# Install cosign (if not already installed)
# See: https://docs.sigstore.dev/system_config/installation/

# Verify the signature with explicit identity checks
cosign verify-blob \
  --certificate-identity 'https://github.com/organization/devbox/.github/workflows/weekly-rebuild.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  --signature devbox.tar.gz.sig \
  devbox.tar.gz

# Output on success:
# Verified OK
```

### Understanding the Identity Fields

- **`--certificate-identity`:** The GitHub Actions workflow that signed this release
  - Format: `https://github.com/ORG/REPO/.github/workflows/WORKFLOW.yml@refs/heads/BRANCH`
  - Ensures the signature came from *this specific workflow*, not a different one
  - Protects against a compromised different workflow signing malicious releases

- **`--certificate-oidc-issuer`:** The OIDC issuer that issued the signing certificate
  - Should always be: `https://token.actions.githubusercontent.com` (GitHub Actions)
  - Proves the signer had a valid GitHub Actions OIDC token at signature time
  - Protects against external signers impersonating GitHub Actions

### Verify the Signature in Rekor (Optional)

For additional transparency, you can verify the signature was recorded in Sigstore's transparency log:

```bash
# Find the Rekor entry by signature
cosign verify-blob-attestation \
  --certificate-identity 'https://github.com/organization/devbox/.github/workflows/weekly-rebuild.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  --signature devbox.tar.gz.sig \
  devbox.tar.gz

# Or, use the rekor CLI directly (if installed)
rekor-cli search --email your-email@example.com | grep devbox

# This shows: the signature is immutable in the transparency log; it can't be deleted or modified after-the-fact
```

## Multi-Architecture (arm64) Caveat

Image digest lockfiles target the CI runner architecture (**x86_64**). If you're deploying on arm64:

### First-Time Setup on arm64

```bash
# Clone and checkout the desired release
git clone https://github.com/organization/devbox.git
cd devbox
git checkout weekly-20260413

# The existing lockfiles are x86_64; regenerate for your architecture
./scripts/update-images.sh --apply

# This pulls images and resolves digests for your local arm64 architecture
# The lockfiles now contain arm64 digests

# Commit or store locally (don't push unless you want to bump the release)
# git add services/ && git commit -m "arm64 digests"  # Optional

# Now install
./setup.sh
```

### Subsequent Installs on arm64

The lockfiles are now arm64-specific. Weekly updates will continue to refresh arm64 digests:

```bash
git pull  # Get the latest x86_64 lockfiles from main
git checkout weekly-YYYYMMDD  # Check out the weekly tag (x86_64)

# Regenerate for arm64
./scripts/update-images.sh --apply

# Install
./setup.sh
```

**Why this is necessary:**
- Docker image manifest lists contain platform-specific digests (x86_64, arm64, etc.)
- `docker compose config --lock-image-digests` resolves to the current platform's digest
- arm64 digests differ from x86_64 digests (different binaries, different dependencies)
- CI runs on x86_64; the committed lockfiles therefore contain x86_64 digests

## Emergency: Sigstore Unavailability

If Sigstore Rekor is unavailable (rare), new signatures cannot be generated, but existing releases remain valid:

```bash
# If you're in the middle of an install and Sigstore is down:
# Option 1: Wait for Sigstore to recover (a few hours at most)
# Option 2: Use the fallback path (not recommended, see below)

# Fallback (untrusted):
DEVBOX_SKIP_SIGNATURE_VERIFY=1 ./setup.sh
# WARNING: This deploys code WITHOUT signature verification. 
# Re-verify after Sigstore recovers and Rekor entry is available.
```

**Important:**
- Existing `weekly-YYYYMMDD` releases remain valid (their signatures were created at build time)
- Only *new* releases would be blocked
- Use this override only in emergencies
- After Sigstore recovers, manually verify the cosign signature before deploying

## Troubleshooting

### `update-images.sh --check` exits 1

**Cause:** Image digests have changed (new patches available within the pinned minor).

**Action:** Run `--apply`, review the diff, and commit if desired.

### SHA mismatch on fetch_and_verify

**Cause:** A development tool (bun, rustup, etc.) released a new version; the pinned SHA no longer matches.

**Action:**
```bash
# Option 1: Update the manifest (preferred)
./scripts/update-manifest.sh --apply
git add scripts/lib/download-manifest.sh
git commit -m "Update download manifest"
./setup.sh

# Option 2: Emergency override (not recommended)
DEVBOX_ALLOW_UNVERIFIED=1 ./setup.sh
# Then update the manifest before the next install
```

### Traefik fails to start after digest update

**Cause:** The newly resolved Traefik digest is broken upstream (rare).

**Action:**
```bash
# Revert the digest update
git revert HEAD

# Redeploy from the prior commit
./start-all.sh

# Investigate what went wrong
docker logs traefik

# File an issue on the Traefik project if it's a known bug
```

## Alpine backup image refresh

`scripts/host/backup.sh` exports named Docker volumes via a pinned alpine image declared in `scripts/lib/devbox-contract.sh` as `ALPINE_BACKUP_IMAGE` (sha256 digest form). Treating this as a contract value keeps backup output reproducible across operator workstations.

### Auto-PR mechanism

`.github/workflows/weekly-rebuild.yml` includes an `alpine-digest-check` job that runs on the same weekly schedule. The job:

1. Resolves the current `alpine:3.21` multi-arch manifest digest via `docker manifest inspect`.
2. Reads the digest currently pinned in `scripts/lib/devbox-contract.sh`.
3. If they match, exits cleanly with no side effect.
4. If they differ, bumps the digest in `devbox-contract.sh` and opens a pull request on a fresh `chore/alpine-digest-refresh-<run-id>` branch.

The workflow **never** commits to `main` directly. Operators review the PR diff and merge (or close) on their own cadence.

### Operator review checklist

When the PR opens:

- Confirm `scripts/lib/devbox-contract.sh` is the only file changed.
- Run `docker manifest inspect alpine@sha256:<new-digest>` locally to confirm the digest resolves on docker.io/library/alpine.
- Make sure no other `ALPINE` references slipped in (the bump is a pure digest swap).
- Merge to ship the new image; close the PR to defer until the next weekly check.

### Manual refresh fallback

If you need to refresh outside the weekly schedule:

```bash
# Resolve the current upstream digest
NEW_DIGEST="$(docker manifest inspect alpine:3.21 \
    | jq -r '.manifests[0].digest // .config.digest // empty')"
echo "${NEW_DIGEST}"
# sha256:<64-hex>

# Replace the digest in the contract
sed -i -E "s|alpine@sha256:[a-f0-9]{64}|alpine@${NEW_DIGEST}|g" \
    scripts/lib/devbox-contract.sh

# Verify the contract still passes Bats
bats tests/contract/contract.bats

# Commit
git add scripts/lib/devbox-contract.sh
git commit -m "chore(contract): refresh ALPINE_BACKUP_IMAGE digest"
```

## References

- **ARCHITECTURE.md:** Digest pinning strategy
- **ARCHITECTURE.md:** Tag pinning and version bumps
- **ARCHITECTURE.md:** Cosign keyless verification
- **docs/security.md:** Trust model and threat boundaries
- **docs/ops.md:** Backup and incident response
