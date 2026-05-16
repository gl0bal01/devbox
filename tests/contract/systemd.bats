#!/usr/bin/env bats
# =============================================================================
# tests/contract/systemd.bats — P3 systemd unit contract assertions
# =============================================================================
# Enforces the v4.1 plan P3 gate:
#   - All three template files exist under scripts/systemd/.
#   - envsubst-rendered units reference the substituted DEVBOX_HOME path.
#   - systemd-analyze verify passes on each rendered unit (skip if unavailable).
#   - install-systemd.sh is shellcheck-clean and bash -n clean.
# =============================================================================

BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
DEVBOX_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
SYSTEMD_TMPL_DIR="${DEVBOX_DIR}/scripts/systemd"
INSTALL_SCRIPT="${DEVBOX_DIR}/scripts/host/install-systemd.sh"

# Test substitution values.
TEST_USER="dev"
TEST_HOME="/tmp/devbox-test"

@test "systemd: devbox.service.template exists" {
    [ -f "${SYSTEMD_TMPL_DIR}/devbox.service.template" ]
}

@test "systemd: devbox-backup.service.template exists" {
    [ -f "${SYSTEMD_TMPL_DIR}/devbox-backup.service.template" ]
}

@test "systemd: devbox-backup.timer.template exists" {
    [ -f "${SYSTEMD_TMPL_DIR}/devbox-backup.timer.template" ]
}

@test "systemd: rendered devbox.service references TEST_HOME in ExecStart/ExecStop/WorkingDirectory" {
    rendered=$(DEVBOX_USER="${TEST_USER}" DEVBOX_HOME="${TEST_HOME}" \
        envsubst '$DEVBOX_USER $DEVBOX_HOME' \
        <"${SYSTEMD_TMPL_DIR}/devbox.service.template")
    echo "${rendered}" | grep -qF "ExecStart=${TEST_HOME}/start-all.sh"
    echo "${rendered}" | grep -qF "ExecStop=${TEST_HOME}/stop-all.sh"
    echo "${rendered}" | grep -qF "WorkingDirectory=${TEST_HOME}"
}

@test "systemd: rendered devbox-backup.service references TEST_HOME in ExecStart" {
    rendered=$(DEVBOX_USER="${TEST_USER}" DEVBOX_HOME="${TEST_HOME}" \
        envsubst '$DEVBOX_USER $DEVBOX_HOME' \
        <"${SYSTEMD_TMPL_DIR}/devbox-backup.service.template")
    echo "${rendered}" | grep -qF "ExecStart=${TEST_HOME}/backup.sh"
}

@test "systemd: rendered devbox-backup.timer contains OnCalendar=daily and Persistent=true" {
    rendered=$(DEVBOX_USER="${TEST_USER}" DEVBOX_HOME="${TEST_HOME}" \
        envsubst '$DEVBOX_USER $DEVBOX_HOME' \
        <"${SYSTEMD_TMPL_DIR}/devbox-backup.timer.template")
    echo "${rendered}" | grep -qF "OnCalendar=daily"
    echo "${rendered}" | grep -qF "Persistent=true"
}

@test "systemd: rendered devbox.service passes systemd-analyze verify" {
    if ! command -v systemd-analyze >/dev/null 2>&1; then
        skip "systemd-analyze not available"
    fi
    tmp="$(mktemp -d)"
    # Create stub executables so systemd-analyze can resolve ExecStart/ExecStop.
    mkdir -p "${tmp}/devbox-home"
    touch "${tmp}/devbox-home/start-all.sh" "${tmp}/devbox-home/stop-all.sh"
    chmod +x "${tmp}/devbox-home/start-all.sh" "${tmp}/devbox-home/stop-all.sh"
    DEVBOX_USER="${TEST_USER}" DEVBOX_HOME="${tmp}/devbox-home" \
        envsubst '$DEVBOX_USER $DEVBOX_HOME' \
        <"${SYSTEMD_TMPL_DIR}/devbox.service.template" \
        >"${tmp}/devbox.service"
    run systemd-analyze verify "${tmp}/devbox.service"
    rm -rf "${tmp}"
    [ "$status" -eq 0 ]
}

@test "systemd: rendered devbox-backup.service passes systemd-analyze verify" {
    if ! command -v systemd-analyze >/dev/null 2>&1; then
        skip "systemd-analyze not available"
    fi
    tmp="$(mktemp -d)"
    # Create stub executable so systemd-analyze can resolve ExecStart.
    mkdir -p "${tmp}/devbox-home"
    touch "${tmp}/devbox-home/start-all.sh" "${tmp}/devbox-home/stop-all.sh" \
          "${tmp}/devbox-home/backup.sh"
    chmod +x "${tmp}/devbox-home/start-all.sh" "${tmp}/devbox-home/stop-all.sh" \
              "${tmp}/devbox-home/backup.sh"
    # Provide devbox.service stub so the Requires= dependency resolves.
    DEVBOX_USER="${TEST_USER}" DEVBOX_HOME="${tmp}/devbox-home" \
        envsubst '$DEVBOX_USER $DEVBOX_HOME' \
        <"${SYSTEMD_TMPL_DIR}/devbox.service.template" \
        >"${tmp}/devbox.service"
    DEVBOX_USER="${TEST_USER}" DEVBOX_HOME="${tmp}/devbox-home" \
        envsubst '$DEVBOX_USER $DEVBOX_HOME' \
        <"${SYSTEMD_TMPL_DIR}/devbox-backup.service.template" \
        >"${tmp}/devbox-backup.service"
    run systemd-analyze verify "${tmp}/devbox-backup.service"
    rm -rf "${tmp}"
    [ "$status" -eq 0 ]
}

@test "systemd: rendered devbox-backup.timer passes systemd-analyze verify" {
    if ! command -v systemd-analyze >/dev/null 2>&1; then
        skip "systemd-analyze not available"
    fi
    tmp="$(mktemp -d)"
    DEVBOX_USER="${TEST_USER}" DEVBOX_HOME="${TEST_HOME}" \
        envsubst '$DEVBOX_USER $DEVBOX_HOME' \
        <"${SYSTEMD_TMPL_DIR}/devbox-backup.timer.template" \
        >"${tmp}/devbox-backup.timer"
    run systemd-analyze verify "${tmp}/devbox-backup.timer"
    rm -rf "${tmp}"
    [ "$status" -eq 0 ]
}

@test "systemd: install-systemd.sh passes bash -n" {
    run bash -n "${INSTALL_SCRIPT}"
    [ "$status" -eq 0 ]
}

@test "systemd: install-systemd.sh passes shellcheck" {
    if ! command -v shellcheck >/dev/null 2>&1; then
        skip "shellcheck not installed"
    fi
    run shellcheck \
        --shell=bash \
        --severity=warning \
        --exclude=SC1091,SC2312 \
        "${INSTALL_SCRIPT}"
    [ "$status" -eq 0 ]
}
