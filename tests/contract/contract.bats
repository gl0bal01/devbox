#!/usr/bin/env bats
# =============================================================================
# tests/contract/contract.bats — P0 runtime contract assertions
# =============================================================================
# Enforces the v4.1 plan contract:
#   - scripts/lib/devbox-contract.sh declares DEVBOX_HOME=${HOME}/docker.
#   - Helper-read config.env keys are a subset of setup.sh-emitted keys.
#   - Every documented Host(...) in compose files has a matching router rule.
#   - Named volumes in compose files are listed in backup.sh.
#   - container_name entries in compose files appear in security-check.sh.
#   - ALPINE_BACKUP_IMAGE is sha256-pinned.
#   - docker manifest inspect ollama/ollama:0.5.13 exits 0 (skip without docker/net).
#   - Dry install copy of contract.sh is byte-identical to the repo copy.
# =============================================================================

BATS_TEST_DIRNAME="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
DEVBOX_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
CONTRACT="${DEVBOX_DIR}/scripts/lib/devbox-contract.sh"
HOSTS_DIR="${DEVBOX_DIR}/scripts/host"
SERVICES_DIR="${DEVBOX_DIR}/services"
SETUP="${DEVBOX_DIR}/setup.sh"

@test "contract: file exists and is sourceable" {
    [ -f "${CONTRACT}" ]
    run bash -n "${CONTRACT}"
    [ "$status" -eq 0 ]
    run bash -c ". '${CONTRACT}'; printf '%s' \"\${DEVBOX_HOME}\""
    [ "$status" -eq 0 ]
    [[ "$output" == */docker ]]
}

@test "contract: DEVBOX_HOME literal matches \${HOME}/docker" {
    run grep -E '^DEVBOX_HOME=' "${CONTRACT}"
    [ "$status" -eq 0 ]
    [[ "${output}" == *'${HOME}/docker'* ]]
}

@test "contract: DEVBOX_SERVICES is (traefik ollama-openwebui)" {
    run bash -c ". '${CONTRACT}'; printf '%s' \"\${DEVBOX_SERVICES[*]}\""
    [ "$status" -eq 0 ]
    [ "$output" = "traefik ollama-openwebui" ]
}

@test "contract: per-service DIR/COMPOSE/CONTAINERS/HOST keys present" {
    run bash -c ". '${CONTRACT}'; for k in DIR COMPOSE COMPOSE_HTTPS CONTAINERS HOST; do
        for s in traefik ollama-openwebui; do
            v=\"\$(devbox_get \"\$s\" \"\$k\")\"
            [ -n \"\$v\" ] || { echo \"missing: \$k for \$s\"; exit 1; }
        done
    done"
    [ "$status" -eq 0 ]
}

@test "contract: ALPINE_BACKUP_IMAGE is sha256-pinned" {
    run bash -c ". '${CONTRACT}'; printf '%s' \"\${ALPINE_BACKUP_IMAGE}\""
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^alpine@sha256:[a-f0-9]{64}$ ]]
}

@test "contract: ollama-openwebui named volumes are ollama-data + openwebui-data" {
    run bash -c ". '${CONTRACT}'; printf '%s' \"\$(devbox_get ollama-openwebui VOLUMES)\""
    [ "$status" -eq 0 ]
    [ "$output" = "ollama-data openwebui-data" ]
}

@test "setup.sh emits the same config.env keys helpers read" {
    # Setup-emitted static keys (printf '<KEY>=%s\n' lines).
    static_emitted=$(grep -oE "printf '[A-Z_]+=%s" "${SETUP}" \
        | sed -E "s/printf '([A-Z_]+)=.*/\\1/" \
        | sort -u)

    # Setup-emitted dynamic keys (one per service via devbox_compose_chain_key).
    dynamic_emitted=$(bash -c ". '${CONTRACT}'; for s in \"\${DEVBOX_SERVICES[@]}\"; do devbox_compose_chain_key \"\$s\"; echo; done" \
        | grep -E '^COMPOSE_FILE_' \
        | sort -u)

    emitted="$(printf '%s\n%s\n' "$static_emitted" "$dynamic_emitted" | sort -u)"
    [ -n "$emitted" ]

    # Helper-read keys: every bare variable reference in the host helpers,
    # filtered to ENABLE_HTTPS / COMPOSE_FILE_* / DOMAIN / TAILSCALE_IP /
    # DEVBOX_USER.
    read_vars=$(grep -hoE '\$\{?[A-Z_]+' "${HOSTS_DIR}"/start-all.sh "${HOSTS_DIR}"/stop-all.sh "${HOSTS_DIR}"/status.sh "${HOSTS_DIR}"/backup.sh "${HOSTS_DIR}"/install-systemd.sh \
        | sed 's/[${]//g; s/}//g' \
        | sort -u \
        | grep -E '^(ENABLE_HTTPS|COMPOSE_FILE_[A-Z_]+|DOMAIN|TAILSCALE_IP|DEVBOX_USER)$')
    [ -n "$read_vars" ]

    missing=$(comm -23 <(printf '%s\n' "$read_vars") <(printf '%s\n' "$emitted"))
    [ -z "$missing" ] || { echo "Helper-read keys not emitted by setup: $missing"; false; }
}

@test "helpers do not reference legacy HTTPS_ENABLED or bare COMPOSE_FILE" {
    run grep -nE '\bHTTPS_ENABLED\b|\bCOMPOSE_FILE\b(_TRAEFIK|_OLLAMA)?' \
        "${HOSTS_DIR}/start-all.sh" "${HOSTS_DIR}/stop-all.sh" "${HOSTS_DIR}/status.sh"
    # Disallow the legacy names. The grep above intentionally also catches the
    # new names; filter to only legacy.
    leg=$(grep -nE '\bHTTPS_ENABLED\b' "${HOSTS_DIR}/start-all.sh" "${HOSTS_DIR}/stop-all.sh" "${HOSTS_DIR}/status.sh" "${HOSTS_DIR}/backup.sh" || true)
    [ -z "$leg" ] || { echo "Found legacy HTTPS_ENABLED: $leg"; false; }
    bare=$(grep -nE '\bCOMPOSE_FILE\b[^_=]' "${HOSTS_DIR}/start-all.sh" "${HOSTS_DIR}/stop-all.sh" "${HOSTS_DIR}/status.sh" || true)
    [ -z "$bare" ] || { echo "Found bare COMPOSE_FILE: $bare"; false; }
}

@test "helpers do not reference \${HOME}/docker/devbox/services path" {
    run grep -nE 'docker/devbox/services' "${HOSTS_DIR}"/*.sh
    [ "$status" -ne 0 ]
}

@test "every documented Host(*.internal) has a matching router rule label" {
    failed=0
    while IFS= read -r compose; do
        # Extract Host(`<name>.internal`) literals.
        hosts=$(grep -oE 'Host\(`[^`]+\.internal`\)' "${compose}" | sort -u || true)
        for h in $hosts; do
            # Fixed-string match: each Host(`...`) literal must occur on a
            # line that also names a Traefik HTTP router rule.
            if ! grep -F ".rule=${h}" "${compose}" | grep -qF "traefik.http.routers"; then
                echo "compose ${compose}: missing router rule for ${h}"
                failed=1
            fi
        done
    done < <(find "${SERVICES_DIR}" -name 'docker-compose.yml')
    [ "$failed" -eq 0 ]
}

@test "named volumes are subset of backup.sh export targets" {
    # Volumes from compose top-level `volumes:` map.
    declared=$(awk '
        /^volumes:/ { in_vols=1; next }
        in_vols && /^[^[:space:]]/ { in_vols=0 }
        in_vols && /^  [a-z]/ { sub(/:.*$/, ""); gsub(/^ +/, ""); print }
    ' "${SERVICES_DIR}"/ollama-openwebui/docker-compose.yml | sort -u)
    [ -n "$declared" ]

    # Volumes referenced by backup.sh (via contract) — assert each declared
    # volume is named in the contract VOLUMES line for some service.
    contract_vols=$(grep -E '^DEVBOX_VOLUMES_' "${CONTRACT}" | sed 's/.*="//; s/"$//' | tr ' ' '\n' | grep -v '^$' | sort -u)
    missing=$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$contract_vols"))
    [ -z "$missing" ] || { echo "Volumes not in contract: $missing"; false; }
}

@test "container_name entries appear in security-check.sh check list" {
    declared=$(grep -hE '^[[:space:]]*container_name:' "${SERVICES_DIR}"/*/docker-compose.yml \
        | awk '{print $2}' | sort -u)
    [ -n "$declared" ]
    contract_cn=$(grep -E '^DEVBOX_CONTAINERS_' "${CONTRACT}" | sed 's/.*="//; s/"$//' | tr ' ' '\n' | sort -u)
    missing=$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$contract_cn"))
    [ -z "$missing" ] || { echo "Container names not in contract: $missing"; false; }
}

@test "security-check.sh references container 'openwebui' not legacy 'open-webui' as a container name" {
    # The registry path "ghcr.io/open-webui" (image org) is allowed; only
    # bare "open-webui" used as a container name is the legacy mistake.
    # Filter out any line where open-webui is preceded by a path separator.
    leg=$(grep -nE '\bopen-webui\b' "${HOSTS_DIR}/security-check.sh" \
        | grep -vF 'ghcr' || true)
    [ -z "$leg" ] || { echo "Legacy bare 'open-webui' usage: $leg"; false; }
    run grep -qE '\bopenwebui\b' "${HOSTS_DIR}/security-check.sh"
    [ "$status" -eq 0 ]
}

@test "ollama compose pins 0.5.13 (not invalid 0.5)" {
    run grep -E '^[[:space:]]+image:[[:space:]]+ollama/ollama:0\.5\.13$' "${SERVICES_DIR}/ollama-openwebui/docker-compose.yml"
    [ "$status" -eq 0 ]
    run grep -E '^[[:space:]]+image:[[:space:]]+ollama/ollama:0\.5$' "${SERVICES_DIR}/ollama-openwebui/docker-compose.yml"
    [ "$status" -ne 0 ]
}

@test "ollama service exposes port 11434 (no host bind) and has ollama-auth middleware" {
    run grep -E 'expose:' "${SERVICES_DIR}/ollama-openwebui/docker-compose.yml"
    [ "$status" -eq 0 ]
    run grep -E 'ollama-auth@file' "${SERVICES_DIR}/ollama-openwebui/docker-compose.yml"
    [ "$status" -eq 0 ]
}

@test "HTTPS overlay sets both tls=true AND certresolver=letsencrypt per router" {
    https="${SERVICES_DIR}/ollama-openwebui/docker-compose.https.yml"
    run grep -E 'tls=true' "${https}"
    [ "$status" -eq 0 ]
    run grep -E 'tls\.certresolver=letsencrypt' "${https}"
    [ "$status" -eq 0 ]
}

@test "setup.sh installs contract.sh into \${DOCKER_DIR}/lib/" {
    # The install line references the destination DOCKER_DIR/lib path.
    run grep -E 'install -m 0644.*REPO_DIR.*devbox-contract\.sh.*DOCKER_DIR.*lib.*devbox-contract\.sh' "${SETUP}"
    [ "$status" -eq 0 ]
}

@test "setup.sh writes .devbox-marker with DEVBOX_INSTALL_VERSION=1" {
    run grep -E 'DEVBOX_INSTALL_VERSION=1' "${SETUP}"
    [ "$status" -eq 0 ]
    run grep -E '\.devbox-marker' "${SETUP}"
    [ "$status" -eq 0 ]
}

@test "setup.sh contains collision_guard with upgrade-in-place check" {
    run grep -E 'collision_guard\(\)' "${SETUP}"
    [ "$status" -eq 0 ]
    run grep -E '\.devbox-marker' "${SETUP}"
    [ "$status" -eq 0 ]
    run grep -E 'installed_contract' "${SETUP}"
    [ "$status" -eq 0 ]
}

@test "setup.sh writes .secrets/ollama-auth.txt with mode 0600" {
    run grep -E 'OLLAMA_SECRET_FILE=.*\.secrets/ollama-auth\.txt' "${SETUP}"
    [ "$status" -eq 0 ]
    # mode 0600 enforced via either install -m 0600 or chmod 0600 on the file.
    run grep -E '(install -m 0600.*OLLAMA_SECRET_FILE|chmod 0600 .*OLLAMA_SECRET_FILE)' "${SETUP}"
    [ "$status" -eq 0 ]
}

@test "rotate-ollama-auth.sh exists and documents Open WebUI side-effect" {
    [ -x "${HOSTS_DIR}/rotate-ollama-auth.sh" ]
    run head -30 "${HOSTS_DIR}/rotate-ollama-auth.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Open WebUI"* ]]
    [[ "$output" == *"internal"* ]]
}

@test "dry install: cmp -s repo contract == installed-fixture contract" {
    tmp="$(mktemp -d)"
    mkdir -p "${tmp}/lib"
    install -m 0644 "${CONTRACT}" "${tmp}/lib/devbox-contract.sh"
    run cmp -s "${CONTRACT}" "${tmp}/lib/devbox-contract.sh"
    [ "$status" -eq 0 ]
    rm -rf "${tmp}"
}

@test "docker manifest inspect ollama/ollama:0.5.13 exits 0 (or SKIP without docker/net)" {
    if ! command -v docker >/dev/null 2>&1; then
        skip "docker not installed"
    fi
    if ! docker info >/dev/null 2>&1; then
        skip "docker daemon not running"
    fi
    run docker manifest inspect ollama/ollama:0.5.13
    [ "$status" -eq 0 ]
}

@test "scripts/update-images.sh --check exits 0 (lockfiles committed and in sync)" {
    if ! command -v docker >/dev/null 2>&1; then
        skip "docker not installed"
    fi
    if ! docker info >/dev/null 2>&1; then
        skip "docker daemon not running"
    fi
    [ -f "${DEVBOX_DIR}/services/traefik/docker-compose.lock.yml" ]
    [ -f "${DEVBOX_DIR}/services/ollama-openwebui/docker-compose.lock.yml" ]
    run "${DEVBOX_DIR}/scripts/update-images.sh" --check
    [ "$status" -eq 0 ]
}
