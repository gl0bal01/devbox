#!/usr/bin/env bats
# Unit tests for scripts/lib/fetch-verify.sh
#
# Strategy: replace `curl` in PATH with a shim that copies a local fixture to
# whatever path follows --output. No network, no http server, no port races.
# This tests every line of fetch_and_verify EXCEPT the literal curl invocation
# (which is just `curl -fsSL --proto '=https' --tlsv1.2 --max-time 300 -o ... <url>`
# and is verified manually by setup.sh runs in production).

BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
DEVBOX_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
LIB_SCRIPT="${DEVBOX_DIR}/scripts/lib/fetch-verify.sh"

WORK_DIR=""
FIXTURE_FILE=""
FIXTURE_SHA=""
FAKE_BIN=""

setup() {
  WORK_DIR="$(mktemp -d)"
  FAKE_BIN="${WORK_DIR}/bin"
  mkdir -p "${FAKE_BIN}"

  FIXTURE_FILE="${WORK_DIR}/fixture.txt"
  printf 'hello devbox fetch-verify test\n' >"${FIXTURE_FILE}"
  FIXTURE_SHA="$(sha256sum "${FIXTURE_FILE}" | awk '{print $1}')"

  # curl shim: parse --output <path> and copy the fixture there. Honour an
  # exit-1 short-circuit when CURL_FAIL=1 (simulates a 404).
  cat >"${FAKE_BIN}/curl" <<SHIM
#!/usr/bin/env bash
# Test-only curl shim. Looks for --output / -o, copies fixture to that path.
if [ "\${CURL_FAIL:-0}" = "1" ]; then
  echo "curl: simulated 404" >&2
  exit 22
fi
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --output|-o) out="\$2"; shift 2 ;;
    *)           shift ;;
  esac
done
if [ -z "\$out" ]; then
  echo "curl shim: no --output given" >&2
  exit 1
fi
cp "${FIXTURE_FILE}" "\$out"
SHIM
  chmod +x "${FAKE_BIN}/curl"

  export PATH="${FAKE_BIN}:${PATH}"
}

teardown() {
  rm -rf "${WORK_DIR}"
}

# Run fetch_and_verify in a clean subshell with the patched PATH.
_fv() {
  local url="$1" sha="$2" dest="$3"
  PATH="${FAKE_BIN}:${PATH}" bash -c "
    source '${LIB_SCRIPT}'
    fetch_and_verify '${url}' '${sha}' '${dest}'
  "
}

@test "fetch_and_verify succeeds on SHA match" {
  local dest="${WORK_DIR}/out/result.txt"
  run _fv "https://example.test/file" "${FIXTURE_SHA}" "${dest}"
  [ "${status}" -eq 0 ]
  [ -f "${dest}" ]
}

@test "fetch_and_verify returns non-zero on SHA mismatch" {
  local dest="${WORK_DIR}/out2/result.txt"
  local bad_sha="0000000000000000000000000000000000000000000000000000000000000000"
  run _fv "https://example.test/file" "${bad_sha}" "${dest}"
  [ "${status}" -ne 0 ]
}

@test "fetch_and_verify returns non-zero on simulated 404" {
  local dest="${WORK_DIR}/out3/result.txt"
  CURL_FAIL=1 run _fv "https://example.test/missing" "deadbeef" "${dest}"
  [ "${status}" -ne 0 ]
  [ ! -f "${dest}" ]
}

@test "no tempfile left in dest dir after successful fetch" {
  local dest_dir="${WORK_DIR}/clean_success"
  mkdir -p "${dest_dir}"
  local dest="${dest_dir}/result.txt"
  run _fv "https://example.test/file" "${FIXTURE_SHA}" "${dest}"
  [ "${status}" -eq 0 ]
  local tmpfiles
  tmpfiles="$(find "${dest_dir}" -name '*.tmp.*' 2>/dev/null)"
  [ -z "${tmpfiles}" ]
}

@test "no tempfile left in dest dir after SHA mismatch failure" {
  local dest_dir="${WORK_DIR}/clean_fail"
  mkdir -p "${dest_dir}"
  local dest="${dest_dir}/result.txt"
  local bad_sha="0000000000000000000000000000000000000000000000000000000000000000"
  _fv "https://example.test/file" "${bad_sha}" "${dest}" 2>/dev/null || true
  local tmpfiles
  tmpfiles="$(find "${dest_dir}" -name '*.tmp.*' 2>/dev/null)"
  [ -z "${tmpfiles}" ]
}

@test "atomic mv lands file at expected destination with mode 0644" {
  local dest_dir="${WORK_DIR}/mode_test"
  mkdir -p "${dest_dir}"
  local dest="${dest_dir}/output.txt"
  run _fv "https://example.test/file" "${FIXTURE_SHA}" "${dest}"
  [ "${status}" -eq 0 ]
  [ -f "${dest}" ]
  local perms
  perms="$(stat -c %a "${dest}")"
  [ "${perms}" = "644" ]
}

@test "DEVBOX_ALLOW_UNVERIFIED=1 accepts bad SHA with warning on stderr" {
  local dest="${WORK_DIR}/unverified/result.txt"
  local bad_sha="0000000000000000000000000000000000000000000000000000000000000000"
  run bash -c "
    PATH='${FAKE_BIN}:${PATH}' DEVBOX_ALLOW_UNVERIFIED=1 bash -c \"
      source '${LIB_SCRIPT}'
      fetch_and_verify 'https://example.test/file' '${bad_sha}' '${dest}'
    \" 2>&1
  "
  [ "${status}" -eq 0 ]
  [ -f "${dest}" ]
  echo "${output}" | grep -q "DEVBOX_ALLOW_UNVERIFIED"
}

@test "tempfile path is in destination directory (no /tmp cross-fs)" {
  # Spy on the tempfile location: replace cp in the shim with one that prints
  # its destination dir. Easier: check that fetch_and_verify uses ${dest}.tmp.${pid}
  # by searching for any *.tmp.* file in the destination directory mid-run via
  # a sentinel cp.
  local dest_dir="${WORK_DIR}/tmploc_test"
  mkdir -p "${dest_dir}"
  local dest="${dest_dir}/output.txt"
  cat >"${FAKE_BIN}/curl" <<SHIM
#!/usr/bin/env bash
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --output|-o) out="\$2"; shift 2 ;;
    *)           shift ;;
  esac
done
# Assert that the output path is in the destination dir (not /tmp)
case "\$out" in
  ${dest_dir}/*) ;;
  *) echo "WRONG_TMPDIR: \$out" >&2; exit 1 ;;
esac
cp "${FIXTURE_FILE}" "\$out"
SHIM
  chmod +x "${FAKE_BIN}/curl"
  run _fv "https://example.test/file" "${FIXTURE_SHA}" "${dest}"
  [ "${status}" -eq 0 ]
  [ -f "${dest}" ]
}

@test "fetch_and_verify usage error on missing args" {
  run bash -c "
    source '${LIB_SCRIPT}'
    fetch_and_verify
  "
  [ "${status}" -ne 0 ]
  echo "${output}" | grep -q "Usage:"
}

@test "destination directory is created if it doesn't exist" {
  local nested="${WORK_DIR}/a/b/c/d"
  local dest="${nested}/result.txt"
  [ ! -d "${nested}" ]
  run _fv "https://example.test/file" "${FIXTURE_SHA}" "${dest}"
  [ "${status}" -eq 0 ]
  [ -d "${nested}" ]
  [ -f "${dest}" ]
}
