#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# scripts/host/htb-vpn.sh with fake sudo/openvpn/ip on PATH.

setup() {
    SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)/scripts/host/htb-vpn.sh"
    T="$(mktemp -d)"
    export DEVBOX_RUN_DIR="${T}/run" HTB_VPN_TUN_WAIT=1 CALLS="${T}/calls"
    mkdir -p "${DEVBOX_RUN_DIR}" "${T}/bin"
    OVPN="${T}/lab.ovpn"
    touch "${OVPN}"
    chmod 644 "${OVPN}"

    # sudo: run the command as the current user.
    printf '#!/usr/bin/env bash\necho "sudo $*" >>"%s"\nexec "$@"\n' "${CALLS}" >"${T}/bin/sudo"
    # openvpn: record argv, start a long-lived stand-in, write its PID.
    cat >"${T}/bin/openvpn" <<EOF
#!/usr/bin/env bash
echo "openvpn \$*" >>"${CALLS}"
while [ \$# -gt 0 ]; do [ "\$1" = --writepid ] && pidfile="\$2"; shift; done
"${T}/bin/openvpn-daemon" 300 >/dev/null 2>&1 3>&- &
echo \$! >"\${pidfile}"
EOF
    # ip: tun0 exists once the sentinel file does.
    cat >"${T}/bin/ip" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *tun0* ]]; then
    [ -f "${T}/tun0" ] || exit 1
    echo "5: tun0    inet 10.10.14.5/23 scope global tun0"
fi
EOF
    # The stand-in daemon's process name must contain "openvpn" (pgrep/pkill match it).
    cp "$(command -v sleep)" "${T}/bin/openvpn-daemon"
    chmod +x "${T}/bin/"*
    export PATH="${T}/bin:${PATH}"
}

teardown() {
    [ -f "${DEVBOX_RUN_DIR}/htb-vpn.pid" ] && kill "$(cat "${DEVBOX_RUN_DIR}/htb-vpn.pid")" 2>/dev/null || true
    rm -rf "${T}"
}

@test "start: daemonizes openvpn with a PID file, tightens ovpn mode, reports the IP" {
    touch "${T}/tun0"
    run "${SCRIPT}" "${OVPN}" start
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"10.10.14.5/23"* ]]
    grep -q -- "--daemon" "${CALLS}"
    grep -q -- "--writepid ${DEVBOX_RUN_DIR}/htb-vpn.pid" "${CALLS}"
    kill -0 "$(cat "${DEVBOX_RUN_DIR}/htb-vpn.pid")"
    [ "$(stat -c %a "${OVPN}")" = 600 ]
}

@test "start: fails with the log path when tun0 never appears" {
    run "${SCRIPT}" "${OVPN}" start
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"htb-vpn.log"* ]]
}

@test "start: replaces a running tunnel" {
    touch "${T}/tun0"
    "${SCRIPT}" "${OVPN}" start
    old="$(cat "${DEVBOX_RUN_DIR}/htb-vpn.pid")"
    run "${SCRIPT}" "${OVPN}" start
    [ "${status}" -eq 0 ]
    sleep 0.2
    run ! kill -0 "${old}"
}

@test "start: missing ovpn file lists alternatives and fails" {
    run "${SCRIPT}" "${T}/nope.ovpn" start
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"not found"* ]]
}

@test "stop: kills only the PID-file process and removes the file" {
    sleep 300 >/dev/null 2>&1 3>&- &
    bystander=$!
    touch "${T}/tun0"
    "${SCRIPT}" "${OVPN}" start
    pid="$(cat "${DEVBOX_RUN_DIR}/htb-vpn.pid")"
    run "${SCRIPT}" "${OVPN}" stop
    [ "${status}" -eq 0 ]
    sleep 0.2
    run ! kill -0 "${pid}"
    kill -0 "${bystander}"
    [ ! -f "${DEVBOX_RUN_DIR}/htb-vpn.pid" ]
    kill "${bystander}"
}

@test "stop: idempotent when nothing runs, never pkills" {
    run "${SCRIPT}" "${OVPN}" stop
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Not running"* ]]
    run ! grep -q pkill "${CALLS}"
}

@test "stop: refuses to signal a PID-file process that is not openvpn" {
    sleep 300 >/dev/null 2>&1 3>&- &
    impostor=$!
    echo "${impostor}" >"${DEVBOX_RUN_DIR}/htb-vpn.pid"
    run "${SCRIPT}" stop
    [[ "${output}" == *"Not running"* ]]
    kill -0 "${impostor}"
    kill "${impostor}"
}

@test "action-first form: stop/status without an ovpn path" {
    touch "${T}/tun0"
    "${SCRIPT}" "${OVPN}" start
    run "${SCRIPT}" status
    [[ "${output}" == *"Connected"* ]]
    run "${SCRIPT}" stop
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Stopped"* ]]
}

@test "status: reflects tun0" {
    run "${SCRIPT}" "${OVPN}" status
    [[ "${output}" == *"Not connected"* ]]
    touch "${T}/tun0"
    run "${SCRIPT}" "${OVPN}" status
    [[ "${output}" == *"Connected"* ]]
}
