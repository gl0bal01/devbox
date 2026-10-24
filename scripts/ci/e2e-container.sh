#!/usr/bin/env bash
# Run scripts/ci/e2e.sh locally inside a throwaway privileged Ubuntu 24.04
# container with systemd and its own Docker daemon, so the host is never
# reconfigured. Needs Docker and ~15 GB of free disk for images.
#
#   scripts/ci/e2e-container.sh          # run, then delete everything
#   KEEP=1 scripts/ci/e2e-container.sh   # leave the container for debugging
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAME="devbox-e2e-$$"
IMAGE=devbox-e2e:noble
VOLUME="${NAME}-docker"   # /var/lib/docker and /var/lib/containerd must not be overlayfs

cleanup() {
    [ "${KEEP:-0}" = 1 ] && { echo "kept: docker exec -it ${NAME} bash"; return; }
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    docker volume rm "${VOLUME}" "${VOLUME}-containerd" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build -q -t "${IMAGE}" - >/dev/null <<'DOCKERFILE'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends systemd systemd-sysv dbus sudo ca-certificates \
      curl gnupg iproute2 openssh-server docker.io docker-compose-v2 rsync \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl mask systemd-firstboot.service getty@tty1.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
DOCKERFILE

docker run -d --name "${NAME}" --privileged --cgroupns=private \
    --tmpfs /run --tmpfs /run/lock \
    -v "${VOLUME}:/var/lib/docker" -v "${VOLUME}-containerd:/var/lib/containerd" \
    -v "${REPO}:/src:ro" \
    "${IMAGE}" >/dev/null

for _ in $(seq 1 60); do
    state=$(docker exec "${NAME}" systemctl is-system-running 2>/dev/null || true)
    case "${state}" in running|degraded) break ;; esac
    sleep 1
done
docker exec "${NAME}" systemctl is-active --quiet docker || docker exec "${NAME}" systemctl start docker

# Copy the tree: setup.sh records its repo path, and /src is read-only.
docker exec "${NAME}" cp -a /src /opt/devbox
token="${MISE_GITHUB_TOKEN:-${GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}}"
docker exec -e DEVBOX_E2E_I_UNDERSTAND=yes -e MISE_GITHUB_TOKEN="${token}" "${NAME}" /opt/devbox/scripts/ci/e2e.sh
