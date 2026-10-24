#!/usr/bin/env bats
# Cross-file invariants: the contract, the compose files (as Compose resolves
# them, not as grep sees them), the locks, and the helpers must agree.

setup_file() {
    export DEVBOX_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    export TAILSCALE_IP=100.64.0.1 DOMAIN=example.com WEBUI_SECRET_KEY=placeholder DEVBOX_GID=1000
    for svc in traefik ollama-openwebui; do
        ( cd "${DEVBOX_DIR}/services/${svc}" && COMPOSE_FILE=docker-compose.yml docker compose config --format json ) \
            >"${BATS_FILE_TMPDIR}/${svc}.json"
        ( cd "${DEVBOX_DIR}/services/${svc}" && COMPOSE_FILE=docker-compose.yml:docker-compose.lock.yml docker compose config --format json ) \
            >"${BATS_FILE_TMPDIR}/${svc}.locked"
    done
}

setup() {
    . "${DEVBOX_DIR}/scripts/lib/devbox-contract.sh"
}

@test "every contract service has a compose project of the same name" {
    for svc in "${DEVBOX_SERVICES[@]}"; do
        [ "$(jq -r .name "${BATS_FILE_TMPDIR}/${svc}.json")" = "${svc}" ]
    done
}

@test "contract container names equal the compose container_name set" {
    for svc in "${DEVBOX_SERVICES[@]}"; do
        want="$(tr ' ' '\n' <<<"$(devbox_get "${svc}" CONTAINERS)" | sort)"
        got="$(jq -r '.services[].container_name' "${BATS_FILE_TMPDIR}/${svc}.json" | sort)"
        [ "${want}" = "${got}" ] || { echo "${svc}: contract=${want} compose=${got}"; false; }
    done
}

@test "contract hosts equal the Host() router rules" {
    for svc in "${DEVBOX_SERVICES[@]}"; do
        want="$(tr ' ' '\n' <<<"$(devbox_get "${svc}" HOST)" | sort)"
        got="$(jq -r '.services[].labels // {} | to_entries[] | select(.key | test("^traefik\\.http\\.routers\\..*\\.rule$")) | .value' \
            "${BATS_FILE_TMPDIR}/${svc}.json" | sed -n 's/^Host(`\(.*\)`)$/\1/p' | sort)"
        [ "${want}" = "${got}" ] || { echo "${svc}: contract=${want} compose=${got}"; false; }
    done
}

@test "backup exclusions name real volume keys" {
    keys="$(jq -r '.volumes // {} | keys[]' "${BATS_FILE_TMPDIR}"/*.json | sort -u)"
    for k in ${DEVBOX_BACKUP_EXCLUDE_VOLUMES}; do
        grep -qx "${k}" <<<"${keys}" || { echo "unknown volume key ${k}"; false; }
    done
}

@test "locks pin exactly the base tags, by digest" {
    for svc in "${DEVBOX_SERVICES[@]}"; do
        while read -r name base; do
            locked="$(jq -r --arg n "${name}" '.services[$n].image' "${BATS_FILE_TMPDIR}/${svc}.locked")"
            # Normalize like Docker: bare names live in docker.io/library/.
            ref="${base}"
            if [[ "${ref}" != */* ]]; then
                ref="docker.io/library/${ref}"
            elif [[ "${ref%%/*}" != *[.:]* && "${ref%%/*}" != localhost ]]; then
                ref="docker.io/${ref}"
            fi
            [[ "${locked}" =~ ^${ref//./\\.}@sha256:[0-9a-f]{64}$ ]] \
                || { echo "${svc}/${name}: base ${base} vs lock ${locked} (run scripts/update-images.sh --apply)"; false; }
        done < <(jq -r '.services | to_entries[] | "\(.key) \(.value.image)"' "${BATS_FILE_TMPDIR}/${svc}.json")
    done
}

@test "every service is hardened: no-new-privileges, cap_drop ALL, memory limit, health check" {
    for svc in "${DEVBOX_SERVICES[@]}"; do
        bad="$(jq -r '.services | to_entries[] | select(
            ((.value.security_opt // []) | index("no-new-privileges:true") | not)
            or ((.value.cap_drop // []) | index("ALL") | not)
            or (.value.mem_limit == null)
            or (.value.healthcheck == null)) | .key' "${BATS_FILE_TMPDIR}/${svc}.json")"
        [ -z "${bad}" ] || { echo "${svc}: ${bad}"; false; }
    done
}

@test "only traefik publishes ports, and only on TAILSCALE_IP" {
    published="$(jq -r '.services | to_entries[] | select(.value.ports) | "\(.key) \(.value.ports[].host_ip)"' "${BATS_FILE_TMPDIR}"/*.json | sort -u)"
    [ "${published}" = "traefik ${TAILSCALE_IP}" ]
}

@test "only docker-socket-proxy mounts the Docker socket, read-only" {
    mounts="$(jq -r '.services | to_entries[] | .key as $s | (.value.volumes // [])[] | select(.source == "/var/run/docker.sock") | "\($s) \(.read_only)"' \
        "${BATS_FILE_TMPDIR}"/*.json)"
    [ "${mounts}" = "docker-socket-proxy true" ]
}

@test "TAILSCALE_IP and WEBUI_SECRET_KEY fail closed when unset" {
    run bash -c "cd '${DEVBOX_DIR}/services/traefik' && TAILSCALE_IP= docker compose -f docker-compose.yml config -q"
    [ "${status}" -ne 0 ]
    run bash -c "cd '${DEVBOX_DIR}/services/ollama-openwebui' && WEBUI_SECRET_KEY= docker compose -f docker-compose.yml config -q"
    [ "${status}" -ne 0 ]
}

@test "helpers source the contract from their own install location" {
    for f in "${DEVBOX_DIR}"/scripts/host/*.sh; do
        case "${f##*/}" in exegol-*|htb-vpn.sh|install-ai-dev-stack.sh) continue ;; esac
        grep -q 'DEVBOX_HOME="${DEVBOX_HOME:-$(cd "$(dirname "${BASH_SOURCE\[0\]}")" && pwd)}"' "${f}" \
            || { echo "${f##*/} must derive DEVBOX_HOME from its location (sudo sets HOME=/root)"; false; }
    done
}

@test "retired helpers stay deleted" {
    for f in $(sed -n 's/^RETIRED_HELPERS=(\(.*\))$/\1/p' "${DEVBOX_DIR}/setup.sh"); do
        [ ! -e "${DEVBOX_DIR}/scripts/host/${f}" ]
    done
}

@test "setup.sh --check passes for a missing install without root" {
    run env DEVBOX_USER="nobody-devbox-test" "${DEVBOX_DIR}/setup.sh" --check
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"No install"* ]]
}
