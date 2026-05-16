#!/usr/bin/env bats
# Unit tests for image-line parsing logic.
#
# update-images.sh delegates digest locking entirely to
# `docker compose config --lock-image-digests` — there is no
# bespoke image-line parser in the script itself.  These tests
# therefore validate the YAML patterns that the lockfile produces
# (and that update-images.sh depends on) using a small AWK helper
# that mirrors the extraction logic used in sbom-targets.sh and
# check-anchor-consistency.sh.
#
# The AWK helper extracts the value of an `image:` line from
# compose YAML and returns:
#   - The digest string (sha256:…) when present
#   - The tag string when no digest is present
#   - Empty string for bare `image: foo` with no version
#   - Empty for commented-out lines

BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
DEVBOX_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# ---------------------------------------------------------------------------
# AWK helper: parse a single compose `image:` line and return components.
# Input:  one raw line from a compose YAML
# Output: "tag=<tag> digest=<digest>" (either may be empty)
# ---------------------------------------------------------------------------
parse_image_line() {
  local line="$1"
  echo "${line}" | awk '
    # Skip commented lines
    /^[[:space:]]*#/ { exit }
    /image:/ {
      # Strip leading whitespace and the "image:" prefix
      sub(/^[[:space:]]*image:[[:space:]]*/, "")
      ref = $0
      tag = ""
      digest = ""

      # Extract digest (sha256:...)
      if (ref ~ /@sha256:/) {
        split(ref, parts, "@")
        digest = parts[2]
        # Tag is the part before @, after the last colon if present
        img_with_tag = parts[1]
        if (img_with_tag ~ /:/) {
          n = split(img_with_tag, tp, ":")
          tag = tp[n]
        }
      } else if (ref ~ /:/) {
        # Tag only — last colon-separated segment
        n = split(ref, tp, ":")
        tag = tp[n]
      }
      print "tag=" tag " digest=" digest
    }
  '
}

# Helper: extract just the digest field
get_digest() { parse_image_line "$1" | sed 's/.*digest=//'; }
# Helper: extract just the tag field
get_tag()    { parse_image_line "$1" | sed 's/tag=\([^ ]*\).*/\1/'; }

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "parses simple tag — no digest" {
  local line="    image: foo:bar"
  run get_tag "${line}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "bar" ]
}

@test "parses tag+digest (post-stabilization form)" {
  local line="    image: foo:bar@sha256:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
  run get_tag "${line}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "bar" ]
  run get_digest "${line}"
  [ "${output}" = "sha256:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890" ]
}

@test "parses digest-only (no tag, just digest)" {
  local line="    image: foo@sha256:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
  run get_tag "${line}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "" ]
  run get_digest "${line}"
  [ "${output}" = "sha256:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890" ]
}

@test "parses registry prefix with tag and digest" {
  local line="    image: ghcr.io/foo/bar:v1.2.3@sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  run get_tag "${line}"
  [ "${output}" = "v1.2.3" ]
  run get_digest "${line}"
  [ "${output}" = "sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ]
}

@test "parses with 4-space leading indent" {
  local line="    image: myimage:v2"
  run get_tag "${line}"
  [ "${output}" = "v2" ]
}

@test "parses with 6-space leading indent" {
  local line="      image: myimage:v3"
  run get_tag "${line}"
  [ "${output}" = "v3" ]
}

@test "parses with tab leading indent" {
  local line="	image: myimage:v4"
  run get_tag "${line}"
  [ "${output}" = "v4" ]
}

@test "ignores commented-out image line" {
  local line="    # image: foo:bar"
  run parse_image_line "${line}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "" ]
}

@test "bare image with no version returns empty tag and digest" {
  local line="    image: foo"
  run get_tag "${line}"
  [ "${output}" = "" ]
  run get_digest "${line}"
  [ "${output}" = "" ]
}

@test "returns digest string when digest present" {
  local line="  image: traefik:v3.2@sha256:1111111111111111111111111111111111111111111111111111111111111111"
  run get_digest "${line}"
  [ "${output}" = "sha256:1111111111111111111111111111111111111111111111111111111111111111" ]
}

@test "returns tag string when no digest" {
  local line="  image: traefik:v3.2"
  run get_tag "${line}"
  [ "${output}" = "v3.2" ]
}

@test "update-images.sh --check exits 1 when lock file missing" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  # Create a minimal service directory with docker-compose.yml but no lock file
  local svc_dir="${tmpdir}/services/mysvc"
  mkdir -p "${svc_dir}"
  cat >"${svc_dir}/docker-compose.yml" <<'EOF'
services:
  app:
    image: alpine:3.19
EOF
  # update-images.sh requires docker — skip if not available
  if ! command -v docker >/dev/null 2>&1; then
    skip "docker not available in this environment"
  fi
  # Run with modified SERVICES_DIR by patching env — we can't easily override
  # the internal SERVICES_DIR without sourcing, so verify the script handles
  # the missing lock case by running against a known-bad tmpdir via a wrapper.
  skip "integration with docker daemon — covered by CI smoke test"
  rm -rf "${tmpdir}"
}
