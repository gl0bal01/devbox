#!/usr/bin/env bash
# harden-fail2ban.sh — install traefik-auth + recidive jails when Traefik is publicly reachable.
#
# WHY
# ---
# fail2ban is a per-source-IP rate limiter. It only helps when:
#   1. The protected service is reachable from a real, attributable
#      source IP (i.e. published on 0.0.0.0 / public IP).
#   2. The service emits structured auth-failure logs that fail2ban
#      can pattern-match.
#
# Traefik on this devbox can be configured either way:
#   - PUBLIC: ports: ["80:80", "443:443"]      → fail2ban makes sense
#   - LOOPBACK or Tailscale-IP-bound: ports: ["${TAILSCALE_IP}:80:80"]
#     → fail2ban is the WRONG layer. From the kernel's perspective the
#     source is the Tailscale (or loopback) IP, not the real attacker.
#     Use Tailscale ACLs / grants instead — banning the wrong source
#     breaks legitimate access without stopping a hostile tailnet peer.
#
# This module strict-detects the Traefik exposure shape and refuses
# to install jails on the loopback / Tailscale-only topology. Operator-
# invoked, idempotent, dry-run by default.
#
# Background + caveats: docs/harden-modules.md
#
# OS support: Debian/Ubuntu only.
#
# Exit codes:
#   0 ok or skipped cleanly
#   1 user error
#   2 environment mismatch (wrong OS, no fail2ban, no Traefik, wrong Traefik topology)

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
APPLY=0
FORCE=0
JAIL_FILE="/etc/fail2ban/jail.d/devbox.local"
FILTER_FILE="/etc/fail2ban/filter.d/traefik-auth.conf"
TRAEFIK_CONTAINER="traefik"
TRAEFIK_LOG_HOST_PATH=""

usage() {
  cat <<EOF
${SCRIPT_NAME} — install traefik-auth + recidive fail2ban jails (Traefik public-route only)

Usage:
  ${SCRIPT_NAME} [--container NAME] [--log-path /host/path/access.log] [--apply] [--force]
  ${SCRIPT_NAME} --help

Flags:
  --container NAME     Traefik container name (default: ${TRAEFIK_CONTAINER}).
  --log-path PATH      Host path of Traefik access.log (required for --apply if Traefik
                       does not bind-mount logs to a host-readable directory).
  --apply              Mutate /etc/fail2ban. Without it the script is dry-run.
  --force              Install even if Traefik is loopback / Tailscale-only.
                       NOT recommended. See docs/harden-modules.md for why.
  --help               Print this message and exit.

Strict Traefik detection (must pass for default install):
  1. Container named "<--container>" is running.
  2. Image prefix matches "traefik:" or "traefik/traefik:".
  3. At least one published port maps the host side to 0.0.0.0
     (i.e. publicly reachable, not bound to a Tailscale IP).
  4. Traefik access.log is enabled and reachable from the host
     (so fail2ban can read it).

Files written (with --apply):
  ${FILTER_FILE}
  ${JAIL_FILE}

Skips cleanly when:
  - fail2ban not installed (no auto apt install — operator decision).
  - Traefik container not running.
  - Traefik bound to a non-public host IP (Tailscale topology). Use
    --force to override; you've been warned.
EOF
}

log()  { printf '[harden-fail2ban] %s\n' "$*"; }
warn() { printf '[harden-fail2ban] WARN: %s\n' "$*" >&2; }
err()  { printf '[harden-fail2ban] ERROR: %s\n' "$*" >&2; }

require_debian() {
  if [ ! -f /etc/debian_version ]; then
    err "Debian/Ubuntu only."
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --container) TRAEFIK_CONTAINER="${2:-}"; shift 2 ;;
    --log-path)  TRAEFIK_LOG_HOST_PATH="${2:-}"; shift 2 ;;
    --apply)     APPLY=1; shift ;;
    --force)     FORCE=1; shift ;;
    --help|-h)   usage; exit 0 ;;
    *)           err "Unknown flag: $1"; usage >&2; exit 1 ;;
  esac
done

require_debian

# --- prereq: fail2ban ----------------------------------------------------
if ! command -v fail2ban-client >/dev/null 2>&1; then
  log "fail2ban not installed — skipped. (apt install fail2ban)"
  exit 0
fi

# --- prereq: docker ------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "docker not installed — Traefik cannot be running. skipped."
  exit 0
fi

# --- detect: Traefik container running ----------------------------------
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$TRAEFIK_CONTAINER"; then
  log "Traefik container '${TRAEFIK_CONTAINER}' not running. skipped."
  exit 0
fi

# --- detect: image prefix -----------------------------------------------
TRAEFIK_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$TRAEFIK_CONTAINER" 2>/dev/null || true)"
if ! printf '%s' "$TRAEFIK_IMAGE" | grep -qE '^(traefik|traefik/traefik):'; then
  err "Container '${TRAEFIK_CONTAINER}' image is '${TRAEFIK_IMAGE}', not traefik:*. Refusing."
  exit 2
fi

# traefik-auth filter regex is pinned to v3.x access-log format.
# Warn (not block) on other major versions so the operator can decide.
TRAEFIK_VERSION_TAG="${TRAEFIK_IMAGE##*:}"
case "$TRAEFIK_VERSION_TAG" in
  v3|v3.*) ;;
  *) warn "Traefik tag '${TRAEFIK_VERSION_TAG}' is not v3.x — traefik-auth filter regex may not match. Verify with: fail2ban-regex <access.log> /etc/fail2ban/filter.d/traefik-auth.conf" ;;
esac

# --- detect: published port topology ------------------------------------
# Need at least one HostIp == "0.0.0.0" / "::" / "" (== all interfaces)
# to call this "publicly reachable". Anything else (Tailscale IP,
# loopback) is the wrong layer for fail2ban.
PUBLIC=0
HOST_IPS_FOUND=""
while IFS= read -r host_ip; do
  HOST_IPS_FOUND="${HOST_IPS_FOUND}${host_ip} "
  case "$host_ip" in
    "0.0.0.0"|"::"|"") PUBLIC=1 ;;
  esac
done < <(docker inspect --format \
  '{{range $p, $bs := .NetworkSettings.Ports}}{{range $bs}}{{.HostIp}}{{"\n"}}{{end}}{{end}}' \
  "$TRAEFIK_CONTAINER" 2>/dev/null || true)

log "Traefik image     : ${TRAEFIK_IMAGE}"
log "Traefik host IPs  : ${HOST_IPS_FOUND:-<none>}"

if [ "$PUBLIC" = 0 ] && [ "$FORCE" = 0 ]; then
  err "Traefik is bound to non-public host IP(s) (Tailscale or loopback)."
  err "fail2ban is the wrong layer for this topology — banning the kernel-"
  err "visible source IP (Tailscale or loopback) would break legitimate"
  err "access without stopping a hostile tailnet peer. Use Tailscale ACLs."
  err "See docs/harden-modules.md."
  err "Override with --force only if you understand the trade-off."
  exit 2
fi

# --- detect: Traefik access.log -----------------------------------------
# Operator can pass --log-path to tell us where the host-readable log
# lives. Otherwise we sniff the bind-mount.
if [ -z "$TRAEFIK_LOG_HOST_PATH" ]; then
  TRAEFIK_LOG_HOST_PATH="$(docker inspect --format \
    '{{range .Mounts}}{{if eq .Destination "/var/log/traefik"}}{{.Source}}{{end}}{{end}}' \
    "$TRAEFIK_CONTAINER" 2>/dev/null || true)"
  if [ -n "$TRAEFIK_LOG_HOST_PATH" ]; then
    TRAEFIK_LOG_HOST_PATH="${TRAEFIK_LOG_HOST_PATH%/}/access.log"
  fi
fi

if [ -z "$TRAEFIK_LOG_HOST_PATH" ]; then
  warn "Could not auto-detect Traefik access.log host path."
  warn "  Pass --log-path /your/host/path/access.log on next run."
  warn "  Traefik must have 'accessLog: {filePath: /var/log/traefik/access.log}' in static config."
  if [ "$APPLY" = 1 ] && [ "$FORCE" = 0 ]; then
    err "Refusing --apply without a usable log path. Use --log-path or --force."
    exit 1
  fi
  TRAEFIK_LOG_HOST_PATH="/var/log/traefik/access.log  # FIXME: edit before reload"
elif [ ! -e "$TRAEFIK_LOG_HOST_PATH" ]; then
  warn "Detected log path '${TRAEFIK_LOG_HOST_PATH}' does not exist on host yet."
  warn "  Verify Traefik static config enables accessLog and bind-mounts /var/log/traefik."
fi

log "Traefik access.log: ${TRAEFIK_LOG_HOST_PATH}"

# --- jail + filter content ----------------------------------------------
# `read -d ''` consumes through EOF and returns 1; `|| true` is intentional.
read -r -d '' FILTER_CONTENT <<'FILTER' || true
# /etc/fail2ban/filter.d/traefik-auth.conf
# Matches HTTP 401 / 403 in Traefik CLF access log.
# Tested against traefik:v3.x access-log format (CommonFormat).
# If Traefik major version moves to v4 and changes the format, regen.
[Definition]
failregex = ^<HOST> - \S+ \[\] "\S+ \S+ \S+" (401|403) .*$
            ^<HOST> - .* "(GET|POST|PUT|DELETE|HEAD|PATCH) [^"]+" (401|403) .*$
ignoreregex =
datepattern = {^LN-BEG}
FILTER

read -r -d '' JAIL_CONTENT <<JAIL || true
# /etc/fail2ban/jail.d/devbox.local
# Installed by devbox/scripts/host/harden-fail2ban.sh
#
# Two jails:
#   traefik-auth — bans IPs that hit too many 401/403s on Traefik routes.
#   recidive     — bans IPs banned by other jails repeatedly (meta-jail).
#
# Only safe when Traefik is publicly reachable. For Tailscale-only setups
# use Tailscale ACLs instead. See devbox/docs/harden-modules.md.

[traefik-auth]
enabled  = true
port     = http,https
filter   = traefik-auth
logpath  = ${TRAEFIK_LOG_HOST_PATH}
maxretry = 5
findtime = 600
bantime  = 3600

[recidive]
enabled  = true
bantime  = 604800
findtime = 86400
maxretry = 3
JAIL

echo
log "FILTER would be written to: ${FILTER_FILE}"
echo '----- 8< -----'
printf '%s\n' "$FILTER_CONTENT"
echo '----- >8 -----'
echo
log "JAIL would be written to:   ${JAIL_FILE}"
echo '----- 8< -----'
printf '%s\n' "$JAIL_CONTENT"
echo '----- >8 -----'
echo

if [ "$APPLY" = 0 ]; then
  log "dry-run complete. re-run with --apply to install."
  exit 0
fi

# --- apply: write files, reload fail2ban --------------------------------
if [ "$(id -u)" -ne 0 ]; then
  err "--apply requires root (writes /etc/fail2ban/...)."
  exit 1
fi

# Idempotency: if files exist with identical content, skip rewrite + reload.
NEED_RELOAD=0
write_if_changed() {
  local target="$1" mode="$2" content="$3"
  if [ -f "$target" ] && printf '%s\n' "$content" | cmp -s - "$target"; then
    log "  unchanged: ${target}"
    return 0
  fi
  install -d -m 0755 "$(dirname "$target")"
  printf '%s\n' "$content" | install -m "$mode" /dev/stdin "$target"
  log "  wrote:     ${target} (mode ${mode})"
  NEED_RELOAD=1
}

write_if_changed "$FILTER_FILE" 0644 "$FILTER_CONTENT"
write_if_changed "$JAIL_FILE"   0644 "$JAIL_CONTENT"

if [ "$NEED_RELOAD" = 1 ]; then
  log "reloading fail2ban"
  fail2ban-client reload || warn "fail2ban-client reload failed; check 'systemctl status fail2ban'"
  log "jail status:"
  fail2ban-client status traefik-auth 2>/dev/null || warn "traefik-auth jail not active — check logpath '${TRAEFIK_LOG_HOST_PATH}' is readable + non-empty"
  fail2ban-client status recidive     2>/dev/null || warn "recidive jail not active"
else
  log "no changes — fail2ban not reloaded"
fi
