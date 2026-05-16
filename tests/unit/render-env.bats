#!/usr/bin/env bats
# Unit tests for the render_env() helper (extracted from setup.sh).
# Sources tests/lib/test-helpers.bash which provides a standalone render_env.

BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
HELPERS="${BATS_TEST_DIRNAME}/../lib/test-helpers.bash"

WORK_DIR=""

setup() {
  WORK_DIR="$(mktemp -d)"
  # shellcheck source=../lib/test-helpers.bash
  source "${HELPERS}"
}

teardown() {
  rm -rf "${WORK_DIR}"
}

# Helper: write a template file and return its path.
_make_template() {
  local path="${WORK_DIR}/$1"
  printf '%s' "$2" >"${path}"
  echo "${path}"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "renders template with whitelisted vars correctly substituted" {
  local tmpl dest
  tmpl="$(_make_template "service.template" 'HOST=${MY_HOST} PORT=${MY_PORT}')"
  dest="${WORK_DIR}/service.env"
  export MY_HOST="example.internal"
  export MY_PORT="8080"

  render_env "${tmpl}" "${dest}" '${MY_HOST} ${MY_PORT}'

  # Check substitution directly (render_env runs in-process since we sourced helpers)
  local content
  content="$(cat "${dest}")"
  [[ "${content}" == *"example.internal"* ]]
  [[ "${content}" == *"8080"* ]]
}

@test "refuses to overwrite an existing destination file" {
  local tmpl dest
  tmpl="$(_make_template "overwrite.template" 'NEW_CONTENT=${MY_VAR}')"
  dest="${WORK_DIR}/overwrite.env"
  printf 'ORIGINAL_CONTENT\n' >"${dest}"
  export MY_VAR="new-value"

  render_env "${tmpl}" "${dest}" '${MY_VAR}'

  # Destination must still contain original content
  local content
  content="$(cat "${dest}")"
  [ "${content}" = "ORIGINAL_CONTENT" ]
}

@test "refuses to overwrite returns exit code 0" {
  local tmpl dest
  tmpl="$(_make_template "overwrite2.template" 'X=${X_VAR}')"
  dest="${WORK_DIR}/overwrite2.env"
  printf 'ORIGINAL\n' >"${dest}"
  export X_VAR="new"

  run bash -c "source '${HELPERS}' && render_env '${tmpl}' '${dest}' '\${X_VAR}'"
  [ "${status}" -eq 0 ]
}

@test "sets mode 0600 on rendered destination" {
  local tmpl dest
  tmpl="$(_make_template "mode.template" 'KEY=${SECRET_VAL}')"
  dest="${WORK_DIR}/mode.env"
  export SECRET_VAL="hunter2"

  render_env "${tmpl}" "${dest}" '${SECRET_VAL}'

  local perms
  perms="$(stat -c %a "${dest}")"
  [ "${perms}" = "600" ]
}

@test "idempotent: re-running with same template and dest returns 0 with no changes" {
  local tmpl dest
  tmpl="$(_make_template "idem.template" 'VALUE=${IDEM_VAR}')"
  dest="${WORK_DIR}/idem.env"
  export IDEM_VAR="stable"

  render_env "${tmpl}" "${dest}" '${IDEM_VAR}'
  local content_first
  content_first="$(cat "${dest}")"

  # Second call — dest already exists, must return 0 and leave file unchanged
  render_env "${tmpl}" "${dest}" '${IDEM_VAR}'
  local content_second
  content_second="$(cat "${dest}")"

  [ "${content_first}" = "${content_second}" ]
}

@test "variables NOT in whitelist are not substituted" {
  local tmpl dest
  # Template has both a whitelisted and a non-whitelisted var
  tmpl="$(_make_template "nowildcard.template" 'ALLOWED=${ALLOWED_VAR}
KEPT_LITERAL=${HOSTNAME_PLACEHOLDER}')"
  dest="${WORK_DIR}/nowildcard.env"
  export ALLOWED_VAR="yes"
  export HOSTNAME_PLACEHOLDER="should-not-be-substituted"

  # Only whitelist ALLOWED_VAR — HOSTNAME_PLACEHOLDER should stay literal
  render_env "${tmpl}" "${dest}" '${ALLOWED_VAR}'

  local content
  content="$(cat "${dest}")"
  # ALLOWED_VAR should be substituted with "yes"
  [[ "${content}" == *"yes"* ]]
  # HOSTNAME_PLACEHOLDER must remain as literal '${HOSTNAME_PLACEHOLDER}'
  [[ "${content}" == *'${HOSTNAME_PLACEHOLDER}'* ]]
}

@test "envsubst silently substitutes empty string when var unset" {
  # Documents known behavior: plain envsubst substitutes empty string for unset vars.
  local tmpl dest
  tmpl="$(_make_template "unset.template" 'KEY=${UNSET_DEVBOX_VAR_XYZ}')"
  dest="${WORK_DIR}/unset.env"
  unset UNSET_DEVBOX_VAR_XYZ 2>/dev/null || true

  render_env "${tmpl}" "${dest}" '${UNSET_DEVBOX_VAR_XYZ}'

  local content
  content="$(cat "${dest}")"
  # envsubst substitutes empty string — 'KEY=' is what we expect
  [ "${content}" = "KEY=" ]
}

@test "creates destination file that previously did not exist" {
  local tmpl dest
  tmpl="$(_make_template "newfile.template" 'DB_HOST=${DB_HOST_VAR}')"
  dest="${WORK_DIR}/newfile.env"
  export DB_HOST_VAR="postgres.internal"

  [ ! -f "${dest}" ]
  render_env "${tmpl}" "${dest}" '${DB_HOST_VAR}'
  [ -f "${dest}" ]
}

@test "render_env does not create dest when dest already exists" {
  local tmpl dest
  tmpl="$(_make_template "guard.template" 'X=${X_VAR2}')"
  dest="${WORK_DIR}/guard.env"
  printf 'guard-original\n' >"${dest}"
  export X_VAR2="new"

  render_env "${tmpl}" "${dest}" '${X_VAR2}'

  local content
  content="$(cat "${dest}")"
  [ "${content}" = "guard-original" ]
}
