#!/usr/bin/env bash
# harden-dnat-scope.sh — restrict Docker DNAT rules to a CIDR (default Tailscale CGNAT).
#
# WHY
# ---
# Default Docker DNAT rules in the nat/PREROUTING DOCKER chain forward
# published container ports from 0.0.0.0/0. On a Tailscale-fronted host,
# any public scanner that can reach the docker bridge interface
# (br-* / docker0) wins. Replace the wide-open DNAT with one scoped to a
# trusted CIDR — the tailnet — so only tailscale peers can reach the
# container even if userland-proxy / firewall is bypassed.
#
# This module is operator-invoked, idempotent, dry-run by default. It
# does not auto-install, does not edit Docker daemon flags, and does not
# touch persistence unless the operator passes --apply AND iptables
# persistence is detected.
#
# Background + caveats: docs/harden-modules.md
#
# OS support: Debian/Ubuntu (iptables-nft via /usr/sbin/iptables).
# IPv4 only; ip6tables variant deferred — see harden-modules.md.
#
# Exit codes:
#   0 ok or skipped cleanly (no offending rule, prereq missing, etc.)
#   1 user error (bad flag, bad CIDR)
#   2 environment mismatch (wrong OS, no iptables)

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_CIDR="100.64.0.0/10"   # Tailscale CGNAT
APPLY=0
CIDR="${DEFAULT_CIDR}"
TARGET_PORT=""
TARGET_DEST=""
BRIDGE=""

usage() {
  cat <<EOF
${SCRIPT_NAME} — scope Docker DNAT rules to a CIDR (default Tailscale CGNAT)

Usage:
  ${SCRIPT_NAME} [--cidr CIDR] [--port PORT] [--dest IP:PORT] [--bridge IFACE] [--apply]
  ${SCRIPT_NAME} --help

Flags:
  --cidr CIDR      Source CIDR allowed through DNAT (default: ${DEFAULT_CIDR}).
  --port PORT      Limit scoping to rules forwarding this dport (default: all in DOCKER chain).
  --dest IP:PORT   Limit scoping to rules with this --to-destination (default: all matching).
  --bridge IFACE   Limit scoping to rules with this -i interface (default: docker0 + br-*).
  --apply          Mutate the live ruleset. Without it the script is dry-run.
  --help           Print this message and exit.

Behavior:
  1. Lists candidate DNAT rules in nat/PREROUTING DOCKER chain.
  2. For each, prints the equivalent CIDR-scoped rule that would replace it.
  3. With --apply: removes the wide-open rule, inserts the scoped rule.
  4. Persists via iptables-save IFF iptables-persistent is installed.

Skips cleanly when:
  - Docker not installed.
  - DOCKER chain absent.
  - No rule sources from 0.0.0.0/0 (already scoped or not present).

Caveats (read once):
  - Docker rebuilds the DOCKER chain on container restart. The scoped
    rule will be wiped on the next 'docker compose up' for the targeted
    service. Persistent fix = userland-proxy=false + bind to Tailscale
    IP in compose ports: spec. This script is a runtime patch, not a
    permanent solution.
  - If you run UFW: raw iptables rules conflict with UFW state. UFW
    reload may wipe the scoped rule. Prefer 'ufw route allow' on
    UFW-managed hosts.
  - DNAT-to-loopback (e.g. ...--to 127.0.0.1:N) requires net.ipv4
    .conf.<bridge>.route_localnet=1. The script warns; it does not set
    the sysctl for you.
EOF
}

log()  { printf '[harden-dnat-scope] %s\n' "$*"; }
warn() { printf '[harden-dnat-scope] WARN: %s\n' "$*" >&2; }
err()  { printf '[harden-dnat-scope] ERROR: %s\n' "$*" >&2; }

require_debian() {
  if [ ! -f /etc/debian_version ]; then
    local detected="unknown"
    [ -r /etc/os-release ] && detected="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
    err "Debian/Ubuntu only (Ubuntu 24.04 supported). Detected: ${detected:-unknown}"
    exit 2
  fi
}

require_iptables() {
  if ! command -v iptables >/dev/null 2>&1; then
    err "iptables not installed. apt install iptables"
    exit 2
  fi
}

valid_cidr() {
  # IPv4 CIDR sanity. Not exhaustive — rejects obvious junk + IPv6.
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cidr)    CIDR="${2:-}"; shift 2 ;;
    --port)    TARGET_PORT="${2:-}"; shift 2 ;;
    --dest)    TARGET_DEST="${2:-}"; shift 2 ;;
    --bridge)  BRIDGE="${2:-}"; shift 2 ;;
    --apply)   APPLY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *)         err "Unknown flag: $1"; usage >&2; exit 1 ;;
  esac
done

if ! valid_cidr "$CIDR"; then
  err "Invalid IPv4 CIDR: $CIDR (IPv6 not supported in v1)"
  exit 1
fi

require_debian
require_iptables

# Docker installed?
if ! command -v docker >/dev/null 2>&1; then
  log "docker not installed — nothing to scope. skipped."
  exit 0
fi

# DOCKER chain exists?
if ! iptables -t nat -L DOCKER -n >/dev/null 2>&1; then
  log "nat/DOCKER chain absent (Docker not running or no published ports). skipped."
  exit 0
fi

# Persistence detection (informational)
PERSIST=""
if [ -d /etc/iptables ] && command -v netfilter-persistent >/dev/null 2>&1; then
  PERSIST="netfilter-persistent"
elif command -v iptables-save >/dev/null 2>&1 && [ -f /etc/iptables/rules.v4 ]; then
  PERSIST="iptables-save"
fi

# Enumerate candidate rules. Format used (parsed line):
#   -A DOCKER -d <dst> ! -i <if> -p tcp -m tcp --dport <p> -j DNAT --to-destination <ip:port>
# Source for ALL such rules is implicitly 0.0.0.0/0 (no -s present).
mapfile -t RULES < <(iptables -t nat -S DOCKER 2>/dev/null | grep -E '^-A DOCKER .* -j DNAT --to-destination' || true)

if [ "${#RULES[@]}" -eq 0 ]; then
  log "no DNAT rules in DOCKER chain. skipped."
  exit 0
fi

CANDIDATES=()
for rule in "${RULES[@]}"; do
  # Skip rules already scoped (have -s)
  if printf '%s' "$rule" | grep -qE '(^|[[:space:]])-s[[:space:]]'; then
    continue
  fi
  # Filter by --port if requested
  if [ -n "$TARGET_PORT" ]; then
    printf '%s' "$rule" | grep -qE -- "--dport[[:space:]]+${TARGET_PORT}([[:space:]]|$)" || continue
  fi
  # Filter by --dest if requested
  if [ -n "$TARGET_DEST" ]; then
    printf '%s' "$rule" | grep -qE -- "--to-destination[[:space:]]+${TARGET_DEST}([[:space:]]|$)" || continue
  fi
  # Filter by --bridge if requested
  if [ -n "$BRIDGE" ]; then
    printf '%s' "$rule" | grep -qE -- "(! -i|-i)[[:space:]]+${BRIDGE}([[:space:]]|$)" || continue
  fi
  CANDIDATES+=("$rule")
done

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  log "no wide-open (0.0.0.0/0) DNAT rules match the filter. skipped."
  exit 0
fi

log "found ${#CANDIDATES[@]} wide-open DNAT rule(s) in nat/DOCKER. cidr=${CIDR}"
echo

ROUTE_LOCALNET_WARNED=0
for rule in "${CANDIDATES[@]}"; do
  # rule starts with "-A DOCKER " — strip "-A " for re-use as -D / -I.
  body="${rule#-A }"
  # Build scoped rule by injecting "-s <CIDR>" right after "DOCKER ".
  # Defensive: refuse to rewrite anything not starting with "DOCKER ",
  # otherwise an unmatched substitution would silently insert an
  # unscoped duplicate (the original string).
  case "$body" in
    "DOCKER "*) scoped="DOCKER -s ${CIDR} ${body#DOCKER }" ;;
    *) warn "  unexpected rule shape (no leading 'DOCKER '): ${body}; skipping"; continue ;;
  esac

  # Detect DNAT-to-loopback for sysctl warning
  if printf '%s' "$rule" | grep -qE -- '--to-destination[[:space:]]+127\.'; then
    if [ "$ROUTE_LOCALNET_WARNED" = 0 ]; then
      # Try to extract the bridge from -i match
      iface=$(printf '%s' "$rule" | sed -nE 's/.*[[:space:]]-i[[:space:]]+([^[:space:]]+).*/\1/p')
      [ -z "$iface" ] && iface="<bridge>"
      warn "DNAT to 127.x detected — verify net.ipv4.conf.${iface}.route_localnet=1"
      warn "  check: sysctl net.ipv4.conf.${iface}.route_localnet"
      warn "  set:   sysctl -w net.ipv4.conf.${iface}.route_localnet=1"
      ROUTE_LOCALNET_WARNED=1
    fi
  fi

  printf '  current : iptables -t nat -A %s\n' "$body"
  printf '  scoped  : iptables -t nat -I %s\n' "$scoped"

  if [ "$APPLY" = 1 ]; then
    # Insert scoped rule first (so traffic from CIDR matches it),
    # then delete the wide-open rule. Order matters — DNAT chain
    # uses first-match.
    # Word-splitting required: $scoped/$body are space-separated iptables
    # tokens; quoting would pass them as a single argv. Rule body must
    # never contain quoted args (e.g. --comment "...") for this to be safe.
    # shellcheck disable=SC2086
    if ! iptables -t nat -I $scoped 2>/dev/null; then
      err "  insert failed; rule left untouched"
      continue
    fi
    # Word-splitting required: $scoped/$body are space-separated iptables
    # tokens; quoting would pass them as a single argv. Rule body must
    # never contain quoted args (e.g. --comment "...") for this to be safe.
    # shellcheck disable=SC2086
    if ! iptables -t nat -D $body 2>/dev/null; then
      warn "  delete of wide-open rule failed; both rules now present (scoped wins by order)"
    fi
    log "  applied"
  fi
  echo
done

if [ "$APPLY" = 1 ]; then
  if [ -n "$PERSIST" ]; then
    case "$PERSIST" in
      netfilter-persistent)
        log "persisting via netfilter-persistent save"
        netfilter-persistent save || warn "netfilter-persistent save failed"
        ;;
      iptables-save)
        log "persisting via iptables-save > /etc/iptables/rules.v4"
        iptables-save > /etc/iptables/rules.v4 || warn "iptables-save write failed"
        ;;
    esac
  else
    warn "no iptables persistence detected — rule lives until reboot"
    warn "  install: apt install iptables-persistent"
  fi
  warn "Docker rebuilds the DOCKER chain on container restart."
  warn "  Re-run this script after 'docker compose up' on the targeted service,"
  warn "  or pin the container ports to a Tailscale IP in compose."
else
  log "dry-run complete. re-run with --apply to mutate."
fi
