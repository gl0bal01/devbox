#!/usr/bin/env bats
# Unit tests for scripts/ci/check-anchor-consistency.sh
#
# Tests run against a temp copy of services/ to avoid mutating the real tree.

BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
DEVBOX_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
SCRIPT="${DEVBOX_DIR}/scripts/ci/check-anchor-consistency.sh"
SERVICES_DIR="${DEVBOX_DIR}/services"

# The canonical x-logging block hash as computed from the committed compose files.
# Verified by: awk '/^x-logging:/ { in_block=1; print; next }
#   in_block && /^[^ \t]/ && NF > 0 { in_block=0 }
#   in_block { print }' services/traefik/docker-compose.yml | sha256sum
CANONICAL_HASH="1b352ca7631dd16546d3615a960e0315d87477f7ee572bf91ac449fdab50643c"

WORK_DIR=""

setup() {
  WORK_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${WORK_DIR}"
}

# Build a patched version of the script that uses WORK_DIR/services as SERVICES_DIR
_make_patched_script() {
  local fake_services="$1"
  local patched="${WORK_DIR}/check-anchor-consistency-patched.sh"
  sed \
    -e "s|SERVICES_DIR=\"\${DEVBOX_DIR}/services\"|SERVICES_DIR=\"${fake_services}\"|g" \
    "${SCRIPT}" >"${patched}"
  chmod +x "${patched}"
  echo "${patched}"
}

# Copy the real services tree into a temp dir
_copy_services() {
  local dest="${WORK_DIR}/services"
  cp -r "${SERVICES_DIR}" "${dest}"
  echo "${dest}"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "returns 0 when all compose files have identical x-logging blocks" {
  local fake_services
  fake_services="$(_copy_services)"
  local patched
  patched="$(_make_patched_script "${fake_services}")"

  run bash "${patched}"
  [ "${status}" -eq 0 ]
}

@test "returns non-zero when one file's x-logging block is mutated" {
  local fake_services
  fake_services="$(_copy_services)"

  # Mutate the x-logging block in the traefik compose file
  local target="${fake_services}/traefik/docker-compose.yml"
  # Change max-size to a different value to create drift
  sed -i 's/max-size: "10m"/max-size: "50m"/' "${target}"

  local patched
  patched="$(_make_patched_script "${fake_services}")"

  run bash "${patched}"
  [ "${status}" -ne 0 ]
}

@test "reports which file diverged on stdout or stderr" {
  local fake_services
  fake_services="$(_copy_services)"

  local target="${fake_services}/traefik/docker-compose.yml"
  sed -i 's/max-size: "10m"/max-size: "99m"/' "${target}"

  local patched
  patched="$(_make_patched_script "${fake_services}")"

  run bash "${patched}" 2>&1
  [ "${status}" -ne 0 ]
  # Output must mention 'traefik' as the diverged file
  [[ "${output}" == *"traefik"* ]]
}

@test "handles service dir with no compose file gracefully" {
  local fake_services
  fake_services="$(_copy_services)"

  # Add an empty service directory with no docker-compose.yml
  mkdir -p "${fake_services}/empty-svc"

  local patched
  patched="$(_make_patched_script "${fake_services}")"

  run bash "${patched}"
  # Should still succeed (empty dir is skipped or produces SKIP message)
  [ "${status}" -eq 0 ]
}

@test "canonical x-logging block hash matches expected value" {
  # Compute the hash from the real committed traefik compose file
  run bash -c "
    block=\$(awk '
      /^x-logging:/ { in_block=1; print; next }
      in_block && /^[^ \t]/ && NF > 0 { in_block=0 }
      in_block { print }
    ' '${SERVICES_DIR}/traefik/docker-compose.yml')
    printf '%s' \"\${block}\" | sha256sum | awk '{print \$1}'
  "
  [ "${status}" -eq 0 ]
  [ "${output}" = "${CANONICAL_HASH}" ]
}

@test "canonical hash is consistent across all committed service compose files" {
  for compose_yml in "${SERVICES_DIR}"/*/docker-compose.yml; do
    local svc
    svc="$(basename "$(dirname "${compose_yml}")")"
    local block
    block="$(awk '
      /^x-logging:/ { in_block=1; print; next }
      in_block && /^[^ \t]/ && NF > 0 { in_block=0 }
      in_block { print }
    ' "${compose_yml}")"

    if [ -z "${block}" ]; then
      continue
    fi

    local sha
    sha="$(printf '%s' "${block}" | sha256sum | awk '{print $1}')"
    if [ "${sha}" != "${CANONICAL_HASH}" ]; then
      echo "FAIL: services/${svc}/docker-compose.yml x-logging hash ${sha} != ${CANONICAL_HASH}" >&3
      return 1
    fi
  done
}

@test "script exits 0 when run against the real services directory" {
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
}

@test "drift message includes DRIFT keyword in output" {
  local fake_services
  fake_services="$(_copy_services)"

  local target="${fake_services}/traefik/docker-compose.yml"
  sed -i 's/max-file: "3"/max-file: "10"/' "${target}"

  local patched
  patched="$(_make_patched_script "${fake_services}")"

  run bash "${patched}" 2>&1
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"DRIFT"* ]]
}
