#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# systemd unit templates render to valid units pointing at the install.

setup() {
    DEVBOX_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    T="$(mktemp -d)"
    mkdir -p "${T}/docker"
    printf '#!/bin/sh\n' >"${T}/docker/start-all.sh"
    cp "${T}/docker/start-all.sh" "${T}/docker/stop-all.sh"
    cp "${T}/docker/start-all.sh" "${T}/docker/backup.sh"
    chmod +x "${T}/docker/"*.sh
    for u in devbox.service devbox-backup.service devbox-backup.timer; do
        DEVBOX_USER="$(id -un)" DEVBOX_HOME="${T}/docker" envsubst '$DEVBOX_USER $DEVBOX_HOME' \
            <"${DEVBOX_DIR}/scripts/systemd/${u}.template" >"${T}/${u}"
    done
}

teardown() {
    rm -rf "${T}"
}

@test "rendered units reference the install and the operator" {
    grep -qx "ExecStart=${T}/docker/start-all.sh" "${T}/devbox.service"
    grep -qx "ExecStop=${T}/docker/stop-all.sh" "${T}/devbox.service"
    grep -qx "ExecStart=${T}/docker/backup.sh" "${T}/devbox-backup.service"
    grep -qx "User=$(id -un)" "${T}/devbox.service"
    grep -qx "User=$(id -un)" "${T}/devbox-backup.service"
    run ! grep -q '\${' "${T}"/devbox.service "${T}"/devbox-backup.service "${T}"/devbox-backup.timer
}

@test "stack unit waits for docker and tailscale; backup does not start the stack" {
    grep -qx 'Requires=docker.service' "${T}/devbox.service"
    grep -q '^After=.*tailscaled.service' "${T}/devbox.service"
    run ! grep -q '^Requires=.*devbox.service' "${T}/devbox-backup.service"
}

@test "timer is daily and persistent" {
    grep -qx 'OnCalendar=daily' "${T}/devbox-backup.timer"
    grep -qx 'Persistent=true' "${T}/devbox-backup.timer"
}

@test "systemd-analyze verify accepts every unit" {
    command -v systemd-analyze >/dev/null || { echo "systemd-analyze required"; false; }
    run systemd-analyze verify "${T}/devbox.service" "${T}/devbox-backup.service" "${T}/devbox-backup.timer"
    echo "${output}"
    [ "${status}" -eq 0 ]
}
