#!/usr/bin/env bats
# Unit tests for scripts/lib/devbox-lib.sh (sourced directly, no copies).

setup() {
    DEVBOX_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    # shellcheck source=../../scripts/lib/devbox-contract.sh
    . "${DEVBOX_DIR}/scripts/lib/devbox-contract.sh"
    # shellcheck source=../../scripts/lib/devbox-lib.sh
    . "${DEVBOX_DIR}/scripts/lib/devbox-lib.sh"
    T="$(mktemp -d)"
}

teardown() {
    rm -rf "${T}"
}

@test "generate_secret: requested length, alphanumeric, unique" {
    a="$(generate_secret 40)"
    b="$(generate_secret 40)"
    [[ "${a}" =~ ^[A-Za-z0-9]{40}$ ]]
    [ "${a}" != "${b}" ]
    [ "${#a}" -eq 40 ]
}

@test "write_atomic: writes stdin with the given mode, leaves no temp files" {
    echo hello | write_atomic "${T}/f" 0640
    [ "$(cat "${T}/f")" = hello ]
    [ "$(stat -c %a "${T}/f")" = 640 ]
    [ "$(ls "${T}" | wc -l)" -eq 1 ]
}

@test "render_template: substitutes only whitelisted variables, overwrites, 0600" {
    printf 'a=${A} b=${B}\n' >"${T}/t"
    echo old >"${T}/out"
    A=1 B=2 render_template "${T}/t" "${T}/out" '$A'
    [ "$(cat "${T}/out")" = 'a=1 b=${B}' ]
    [ "$(stat -c %a "${T}/out")" = 600 ]
}

@test "render_once: never overwrites an existing destination" {
    printf 'v=${V}\n' >"${T}/t"
    V=first render_once "${T}/t" "${T}/out" '$V'
    V=second render_once "${T}/t" "${T}/out" '$V'
    [ "$(cat "${T}/out")" = v=first ]
}

@test "ensure_credential: created once, stable across calls, mode 0600" {
    ensure_credential "${T}/s/cred.txt" ollama
    first="$(cat "${T}/s/cred.txt")"
    ensure_credential "${T}/s/cred.txt" ollama
    [ "$(cat "${T}/s/cred.txt")" = "${first}" ]
    [[ "${first}" =~ ^ollama:[A-Za-z0-9]{32}$ ]]
    [ "$(stat -c %a "${T}/s/cred.txt")" = 600 ]
    [ "$(stat -c %a "${T}/s")" = 700 ]
}

@test "rotate_credential: replaces the password" {
    ensure_credential "${T}/cred.txt" ollama
    before="$(credential_pass "${T}/cred.txt")"
    rotate_credential "${T}/cred.txt" ollama
    [ "$(credential_user "${T}/cred.txt")" = ollama ]
    [ "$(credential_pass "${T}/cred.txt")" != "${before}" ]
}

@test "render_basic_auth: hash verifies against the credential and is not \$\$-escaped" {
    ensure_credential "${T}/cred.txt" admin
    render_basic_auth dashboard-auth "${T}/cred.txt" "${T}/auth.yml"
    line="$(sed -n 's/^ *- "\(.*\)"$/\1/p' "${T}/auth.yml")"
    user="${line%%:*}"
    hash="${line#*:}"
    [ "${user}" = admin ]
    [[ "${hash}" == '$apr1$'* ]]
    [[ "${hash}" != *'$$'* ]]
    salt="$(cut -d'$' -f3 <<<"${hash}")"
    [ "$(credential_pass "${T}/cred.txt" | openssl passwd -apr1 -salt "${salt}" -stdin)" = "${hash}" ]
    grep -q '^    dashboard-auth:$' "${T}/auth.yml"
    [ "$(stat -c %a "${T}/auth.yml")" = 640 ]
}

@test "env_set: upserts in place, keeps order, mode and other keys" {
    printf 'A=1\nCOMPOSE_FILE=old\nB=2\n' >"${T}/.env"
    chmod 0640 "${T}/.env"
    env_set "${T}/.env" COMPOSE_FILE 'x.yml:y.yml'
    env_set "${T}/.env" NEW 'v&a\l|ue'
    [ "$(cat "${T}/.env")" = "$(printf 'A=1\nCOMPOSE_FILE=x.yml:y.yml\nB=2\nNEW=v&a\\l|ue')" ]
    [ "$(stat -c %a "${T}/.env")" = 640 ]
}

@test "env_set: creates a missing file with mode 0600" {
    env_set "${T}/.env" K v
    [ "$(cat "${T}/.env")" = K=v ]
    [ "$(stat -c %a "${T}/.env")" = 600 ]
}

@test "env_default: keeps an operator value, adds a missing key" {
    printf 'OLLAMA_CPUS=8\n' >"${T}/.env"
    env_default "${T}/.env" OLLAMA_CPUS 2
    env_default "${T}/.env" OTHER x
    [ "$(env_get "${T}/.env" OLLAMA_CPUS)" = 8 ]
    [ "$(env_get "${T}/.env" OTHER)" = x ]
}

@test "env_unset: removes keys, tolerates missing file and missing keys" {
    printf 'A=1\nOVH_X=s\nB=2\n' >"${T}/.env"
    env_unset "${T}/.env" OVH_X NOPE
    [ "$(cat "${T}/.env")" = "$(printf 'A=1\nB=2')" ]
    env_unset "${T}/missing" A
}

@test "compose_file_chain: base, optional overlays, lock last" {
    d="${T}/svc"
    mkdir -p "${d}"
    touch "${d}/docker-compose.yml" "${d}/docker-compose.https.yml" "${d}/docker-compose.gpu.yml" "${d}/docker-compose.lock.yml"
    [ "$(compose_file_chain "${d}" false none)" = docker-compose.yml:docker-compose.lock.yml ]
    [ "$(compose_file_chain "${d}" true none)" = docker-compose.yml:docker-compose.https.yml:docker-compose.lock.yml ]
    [ "$(compose_file_chain "${d}" true nvidia)" = docker-compose.yml:docker-compose.https.yml:docker-compose.gpu.yml:docker-compose.lock.yml ]
    rm "${d}/docker-compose.gpu.yml" "${d}/docker-compose.lock.yml"
    [ "$(compose_file_chain "${d}" false nvidia)" = docker-compose.yml ]
}

@test "compose_file_chain: every real service chain ends with its lock" {
    for svc in "${DEVBOX_SERVICES[@]}"; do
        [[ "$(compose_file_chain "${DEVBOX_DIR}/services/${svc}" false none)" == *:docker-compose.lock.yml ]]
    done
}

@test "collision_guard: accepts missing, empty, prior-install and devbox-only trees" {
    collision_guard "${T}/absent" "${DEVBOX_DIR}"
    mkdir -p "${T}/empty"
    collision_guard "${T}/empty" "${DEVBOX_DIR}"
    mkdir -p "${T}/ours/traefik" "${T}/ours/.secrets"
    touch "${T}/ours/start-all.sh"
    collision_guard "${T}/ours" "${DEVBOX_DIR}"
    mkdir -p "${T}/prior/lib"
    touch "${T}/prior/lib/devbox-contract.sh" "${T}/prior/lib/.devbox-marker" "${T}/prior/foreign"
    collision_guard "${T}/prior" "${DEVBOX_DIR}"
}

@test "collision_guard: rejects foreign entries and names them" {
    mkdir -p "${T}/theirs"
    touch "${T}/theirs/docker-compose.yml" "${T}/theirs/.hidden"
    run collision_guard "${T}/theirs" "${DEVBOX_DIR}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *docker-compose.yml* ]]
    [[ "${output}" == *.hidden* ]]
}

@test "collision_guard: contract without marker is not a prior install" {
    mkdir -p "${T}/half/lib"
    touch "${T}/half/lib/devbox-contract.sh" "${T}/half/foreign"
    run collision_guard "${T}/half" "${DEVBOX_DIR}"
    [ "${status}" -ne 0 ]
}

@test "gpg_export_pinned: exports only the pinned key, rejects a mismatch" {
    export GNUPGHOME="${T}/gnupg"
    mkdir -m 0700 "${GNUPGHOME}"
    for n in good other; do
        gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
            --quick-gen-key "${n} <${n}@example.invalid>" ed25519 sign never 2>/dev/null
    done
    good="$(gpg --batch --with-colons --list-keys good@example.invalid | awk -F: '$1 == "fpr" { print $10; exit }')"
    gpg --batch --export --armor >"${T}/both.asc"

    gpg_export_pinned "${T}/both.asc" "${good}" "${T}/keyring.gpg"
    [ "$(gpg --batch --with-colons --show-keys "${T}/keyring.gpg" | grep -c '^pub:')" -eq 1 ]
    gpg --batch --with-colons --show-keys "${T}/keyring.gpg" | grep -q "^fpr:*${good}:"

    run gpg_export_pinned "${T}/both.asc" 0000000000000000000000000000000000000000 "${T}/bad.gpg"
    [ "${status}" -ne 0 ]
    [ ! -e "${T}/bad.gpg" ]
}

@test "pins: fingerprints and commit are full-length hex" {
    . "${DEVBOX_DIR}/scripts/lib/pins.sh"
    [[ "${TAILSCALE_APT_KEY_FPR}" =~ ^[0-9A-F]{40}$ ]]
    [[ "${MISE_APT_KEY_FPR}" =~ ^[0-9A-F]{40}$ ]]
    [[ "${OHMYZSH_COMMIT}" =~ ^[0-9a-f]{40}$ ]]
}
