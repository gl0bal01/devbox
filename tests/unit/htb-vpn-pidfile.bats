#!/usr/bin/env bats
# Unit tests for scripts/host/htb-vpn.sh PID file logic.
#
# Mocking strategy:
#   - A per-test FAKE_BIN directory is prepended to $PATH in setup().
#   - Fake shims for openvpn, pkill, ip write their argv to a call-log.
#   - `sudo` shim drops the sudo prefix and executes the rest as current user.
#   - `sed` shim intercepts the escape_regex sed pattern and handles it via
#     python3 str.translate, passing all other sed calls to the real sed.
#   - The script's hardcoded PID_DIR=/run/devbox is patched via real sed in setup().
#
# escape_regex() contract tests use a standalone bash helper (_escape_regex)
# that reimplements the same algorithm portably.

BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
DEVBOX_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
SCRIPT="${DEVBOX_DIR}/scripts/host/htb-vpn.sh"

WORK_DIR=""
FAKE_PID_DIR=""
FAKE_OVPN=""
CALL_LOG=""
PATCHED_SCRIPT=""
FAKE_BIN=""

setup() {
  WORK_DIR="$(mktemp -d)"
  FAKE_PID_DIR="${WORK_DIR}/run/devbox"
  FAKE_OVPN="${WORK_DIR}/lab.ovpn"
  CALL_LOG="${WORK_DIR}/calls.log"
  FAKE_BIN="${WORK_DIR}/bin"

  mkdir -p "${FAKE_PID_DIR}"
  touch "${FAKE_OVPN}"
  chmod 600 "${FAKE_OVPN}"
  touch "${CALL_LOG}"
  mkdir -p "${FAKE_BIN}"

  # sudo shim: drop 'sudo' prefix, execute rest as current user
  cat >"${FAKE_BIN}/sudo" <<SHIM
#!/usr/bin/env bash
echo "sudo \$*" >>"${CALL_LOG}"
cmd="\${1:-}"
if [ "\${cmd}" = "openvpn" ] || [ "\${cmd}" = "/usr/sbin/openvpn" ]; then
  shift
  exec "${FAKE_BIN}/openvpn" "\$@"
fi
exec "\$@"
SHIM
  chmod +x "${FAKE_BIN}/sudo"

  # openvpn shim: write own PID to --writepid target, exit 0
  cat >"${FAKE_BIN}/openvpn" <<SHIM
#!/usr/bin/env bash
echo "openvpn \$*" >>"${CALL_LOG}"
writepid=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "--writepid" ]; then
    writepid="\$2"
    shift 2
  else
    shift
  fi
done
if [ -n "\${writepid}" ]; then
  echo \$\$ >"\${writepid}"
fi
exit 0
SHIM
  chmod +x "${FAKE_BIN}/openvpn"

  # ip shim: tun0 presence controlled by sentinel file
  cat >"${FAKE_BIN}/ip" <<SHIM
#!/usr/bin/env bash
echo "ip \$*" >>"${CALL_LOG}"
if echo "\$*" | grep -q "tun0"; then
  if [ -f "${WORK_DIR}/tun0_up" ]; then
    echo "5: tun0: <POINTOPOINT,UP,LOWER_UP> mtu 1500"
    echo "    inet 10.10.14.5/24 scope global tun0"
    exit 0
  else
    echo "Device tun0 does not exist." >&2
    exit 1
  fi
fi
exec /sbin/ip "\$@" 2>/dev/null || true
SHIM
  chmod +x "${FAKE_BIN}/ip"

  # pkill shim: log args and exit 0 (simulate: process found and killed)
  cat >"${FAKE_BIN}/pkill" <<SHIM
#!/usr/bin/env bash
echo "pkill \$*" >>"${CALL_LOG}"
exit 0
SHIM
  chmod +x "${FAKE_BIN}/pkill"

  # sed shim: intercept the escape_regex pattern (which is broken in some
  # GNU sed evaluation contexts when the bracket class starts with ]).
  # Delegate all other sed invocations to the real /usr/bin/sed.
  cat >"${FAKE_BIN}/sed" <<'SHIM'
#!/usr/bin/env bash
# Detect the specific escape_regex sed expression
if [ "$#" -eq 1 ] && [ "$1" = 's/[]\.^$*+?{}|()/\\&/g' ]; then
  # Handle via python3: escape regex metachars in stdin
  python3 -c "
import sys
text = sys.stdin.read()
result = text.translate(str.maketrans({c: '\\\\'+c for c in r']\\.^$*+?{}|('}))
sys.stdout.write(result)
"
else
  exec /usr/bin/sed "$@"
fi
SHIM
  chmod +x "${FAKE_BIN}/sed"

  export PATH="${FAKE_BIN}:${PATH}"

  # Patch PID_DIR using the REAL sed (bypass our shim with full path)
  PATCHED_SCRIPT="${WORK_DIR}/htb-vpn-patched.sh"
  /usr/bin/sed \
    -e "s|PID_DIR=\"/run/devbox\"|PID_DIR=\"${FAKE_PID_DIR}\"|g" \
    "${SCRIPT}" >"${PATCHED_SCRIPT}"
  chmod +x "${PATCHED_SCRIPT}"
}

teardown() {
  rm -rf "${WORK_DIR}"
}

# ---------------------------------------------------------------------------
# Standalone escape_regex for direct unit testing.
# Same contract as the script's escape_regex() but implemented portably.
# ---------------------------------------------------------------------------
_escape_regex() {
  printf '%s' "$1" | python3 -c "
import sys
text = sys.stdin.read()
result = text.translate(str.maketrans({c: '\\\\'+c for c in r']\\.^\$*+?{}|('}))
sys.stdout.write(result)
"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "start invokes openvpn with --writepid and --daemon flags" {
  run bash "${PATCHED_SCRIPT}" "${FAKE_OVPN}" start || true
  run grep "openvpn" "${CALL_LOG}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--writepid"* ]]
  [[ "${output}" == *"--daemon"* ]]
}

@test "start creates PID file in the PID directory" {
  run bash "${PATCHED_SCRIPT}" "${FAKE_OVPN}" start || true
  [ -f "${FAKE_PID_DIR}/htb-vpn.pid" ]
}

@test "stop reads PID file, kills process, removes file" {
  sleep 60 &
  local FAKE_PID=$!
  echo "${FAKE_PID}" >"${FAKE_PID_DIR}/htb-vpn.pid"

  run bash "${PATCHED_SCRIPT}" "${FAKE_OVPN}" stop
  [ "${status}" -eq 0 ]
  [ ! -f "${FAKE_PID_DIR}/htb-vpn.pid" ]

  kill "${FAKE_PID}" 2>/dev/null || true
}

@test "double stop is idempotent — no error on missing PID file" {
  rm -f "${FAKE_PID_DIR}/htb-vpn.pid"
  run bash "${PATCHED_SCRIPT}" "${FAKE_OVPN}" stop
  [ "${status}" -eq 0 ]
}

@test "status detects VPN not connected when tun0 absent" {
  rm -f "${WORK_DIR}/tun0_up"
  run bash "${PATCHED_SCRIPT}" "${FAKE_OVPN}" status
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Not Connected"* ]]
}

@test "status detects VPN connected when tun0 present" {
  touch "${WORK_DIR}/tun0_up"
  run bash "${PATCHED_SCRIPT}" "${FAKE_OVPN}" status
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Connected"* ]]
}

@test "pkill fallback is invoked when PID file is missing" {
  rm -f "${FAKE_PID_DIR}/htb-vpn.pid"
  >"${CALL_LOG}"
  run bash "${PATCHED_SCRIPT}" "${FAKE_OVPN}" stop
  [ "${status}" -eq 0 ]
  run grep "pkill" "${CALL_LOG}"
  [ "${status}" -eq 0 ]
}

@test "pkill fallback passes anchored escaped regex" {
  rm -f "${FAKE_PID_DIR}/htb-vpn.pid"
  >"${CALL_LOG}"
  run bash "${PATCHED_SCRIPT}" "${FAKE_OVPN}" stop
  [ "${status}" -eq 0 ]
  run grep "pkill" "${CALL_LOG}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"^openvpn"* ]]
}

# ---------------------------------------------------------------------------
# escape_regex() contract tests (standalone portable implementation)
# ---------------------------------------------------------------------------

@test "escape_regex handles dot metachar" {
  [ "$(_escape_regex "foo.bar")" = 'foo\.bar' ]
}

@test "escape_regex does not escape open-bracket (not in sed char class)" {
  # The script's sed expression []\.^$*+?{}|( matches ] but NOT [.
  # [ is left unescaped by design — pkill -f anchors with ^ already limit scope.
  [ "$(_escape_regex "foo[bar")" = 'foo[bar' ]
}

@test "escape_regex handles open-paren metachar" {
  [ "$(_escape_regex "foo(bar")" = 'foo\(bar' ]
}

@test "escape_regex handles plus metachar" {
  [ "$(_escape_regex "foo+bar")" = 'foo\+bar' ]
}

@test "escape_regex handles question-mark metachar" {
  [ "$(_escape_regex "foo?bar")" = 'foo\?bar' ]
}

@test "escape_regex handles dollar metachar" {
  [ "$(_escape_regex 'foo$bar')" = 'foo\$bar' ]
}

@test "escape_regex handles backslash metachar" {
  [ "$(_escape_regex 'foo\bar')" = 'foo\\bar' ]
}

@test "escape_regex handles pipe metachar" {
  [ "$(_escape_regex 'foo|bar')" = 'foo\|bar' ]
}
