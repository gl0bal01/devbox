#!/usr/bin/env bash
# harden-backup-skeleton.sh — install a generic age-encrypted, systemd-timed backup pipeline.
#
# WHY
# ---
# Service-agnostic encrypted-backup skeleton. Caller passes --tag and one
# or more --path; the script lays down:
#   /usr/local/sbin/<tag>-backup                  (the runner)
#   /etc/systemd/system/<tag>-backup.service      (oneshot)
#   /etc/systemd/system/<tag>-backup.timer        (daily, RandomizedDelay)
#   /etc/<tag>-backup/                            (config dir; offsite env)
#   /etc/<tag>-backup/backup-offsite.env.example
#   /var/backups/<tag>/                           (local output, 0700)
#   /var/log/<tag>-backup-offsite.log             (rclone errors only)
#
# Encryption recipient: /root/.config/<tag>-backup/recipient.pub
# (operator generates the keypair separately — key management is
# opinionated; see docs/harden-modules.md for the keygen recipe).
#
# Properties:
#   - tar streamed to age (no plaintext on disk)
#   - 14-day local retention by default
#   - off-site push opt-in via /etc/<tag>-backup/backup-offsite.env (REMOTE=)
#   - idempotent install (re-run is safe)
#   - --uninstall removes the runner + units, KEEPS backups + recipient.pub
#
# Background + caveats: docs/harden-modules.md
#
# OS support: Debian/Ubuntu with systemd.
#
# Exit codes:
#   0 ok or skipped cleanly
#   1 user error (bad tag, bad path, missing required flag)
#   2 environment mismatch (wrong OS, no systemd, missing prereq)

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
APPLY=0
UNINSTALL=0
TAG=""
PATHS=()
RETENTION=14
RECIPIENT_FILE=""
OUT_DIR=""

usage() {
  cat <<EOF
${SCRIPT_NAME} — install a generic age-encrypted backup pipeline (per-service)

Usage:
  ${SCRIPT_NAME} --tag NAME --path /abs/path [--path /abs/path ...] \\
                 [--retention DAYS] [--recipient-file PATH] [--out DIR] [--apply]
  ${SCRIPT_NAME} --tag NAME --uninstall [--apply]
  ${SCRIPT_NAME} --help

Required:
  --tag NAME           Service tag. Must match ^[a-z][a-z0-9-]{1,30}\$
                       Used as namespace for script, units, dirs.
  --path PATH          Absolute path to include in the tarball. Repeat
                       for multiple. Must exist. '/' is rejected.

Optional:
  --retention DAYS     Local + offsite retention (1..365). Default: ${RETENTION}.
  --recipient-file P   age recipient pubkey path. Default:
                       /root/.config/<tag>-backup/recipient.pub
  --out DIR            Local backup directory. Default: /var/backups/<tag>
  --apply              Mutate the system. Without it the script is dry-run.
  --uninstall          Remove the runner + systemd units. KEEPS:
                         /var/backups/<tag>/      (your backups)
                         /root/.config/<tag>-backup/recipient.pub
                         /etc/<tag>-backup/       (offsite env)
  --help               Print this message and exit.

Prereqs (--apply checks; dry-run only warns):
  - systemd
  - age      (apt install age)
  - tar      (always present)
  - rclone   (only if you wire offsite via REMOTE=)
  - age recipient pubkey at the resolved --recipient-file path
    (generate with: age-keygen -o /root/.config/<tag>-backup/identity.txt
     then extract the '# public key:' line into recipient.pub.
     See docs/harden-modules.md for the full keygen recipe.)

Smoke-test after --apply:
  systemctl list-timers <tag>-backup.timer
  /usr/local/sbin/<tag>-backup
  ls -lh /var/backups/<tag>/

Restore (operator-side, manually):
  age -d -i <identity.txt> < /var/backups/<tag>/<tag>-<stamp>.tar.age \\
    | tar -xzf - -C /
EOF
}

log()  { printf '[harden-backup-skeleton] %s\n' "$*"; }
warn() { printf '[harden-backup-skeleton] WARN: %s\n' "$*" >&2; }
err()  { printf '[harden-backup-skeleton] ERROR: %s\n' "$*" >&2; }

require_debian() {
  if [ ! -f /etc/debian_version ]; then
    err "Debian/Ubuntu only."
    exit 2
  fi
}

require_systemd() {
  if [ ! -d /run/systemd/system ] && ! pidof systemd >/dev/null 2>&1; then
    err "systemd required (no /run/systemd/system, no systemd PID)."
    exit 2
  fi
}

valid_tag() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{1,30}$ ]]
}

# --- arg parse -----------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --tag)            TAG="${2:-}"; shift 2 ;;
    --path)           PATHS+=("${2:-}"); shift 2 ;;
    --retention)      RETENTION="${2:-}"; shift 2 ;;
    --recipient-file) RECIPIENT_FILE="${2:-}"; shift 2 ;;
    --out)            OUT_DIR="${2:-}"; shift 2 ;;
    --apply)          APPLY=1; shift ;;
    --uninstall)      UNINSTALL=1; shift ;;
    --help|-h)        usage; exit 0 ;;
    *)                err "Unknown flag: $1"; usage >&2; exit 1 ;;
  esac
done

# --- validate ------------------------------------------------------------
if [ -z "$TAG" ]; then
  err "--tag NAME required"
  exit 1
fi

if ! valid_tag "$TAG"; then
  err "tag '${TAG}' invalid. Must match ^[a-z][a-z0-9-]{1,30}\$"
  exit 1
fi

require_debian

# Derived paths
RUNNER="/usr/local/sbin/${TAG}-backup"
SVC_FILE="/etc/systemd/system/${TAG}-backup.service"
TIMER_FILE="/etc/systemd/system/${TAG}-backup.timer"
ETC_DIR="/etc/${TAG}-backup"
OFFSITE_ENV="${ETC_DIR}/backup-offsite.env"
OFFSITE_EXAMPLE="${ETC_DIR}/backup-offsite.env.example"
[ -z "$RECIPIENT_FILE" ] && RECIPIENT_FILE="/root/.config/${TAG}-backup/recipient.pub"
[ -z "$OUT_DIR" ]        && OUT_DIR="/var/backups/${TAG}"
LOG_FILE="/var/log/${TAG}-backup-offsite.log"

# --- uninstall path -----------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  log "uninstall plan (tag=${TAG}):"
  log "  remove ${RUNNER}"
  log "  remove ${SVC_FILE}"
  log "  remove ${TIMER_FILE}"
  log "  KEEP   ${OUT_DIR}    (your backups)"
  log "  KEEP   ${RECIPIENT_FILE}    (encryption pubkey)"
  log "  KEEP   ${ETC_DIR}/   (offsite env)"
  if [ "$APPLY" = 0 ]; then
    log "dry-run complete. re-run with --uninstall --apply to remove."
    exit 0
  fi
  if [ "$(id -u)" -ne 0 ]; then
    err "--apply requires root"
    exit 1
  fi
  require_systemd
  systemctl disable --now "${TAG}-backup.timer" 2>/dev/null || true
  rm -f "$RUNNER" "$SVC_FILE" "$TIMER_FILE"
  systemctl daemon-reload
  log "uninstalled."
  exit 0
fi

# Install path requires --path
if [ "${#PATHS[@]}" -eq 0 ]; then
  err "at least one --path /abs/path is required for install"
  exit 1
fi

# Validate retention
if ! [[ "$RETENTION" =~ ^[0-9]+$ ]] || [ "$RETENTION" -lt 1 ] || [ "$RETENTION" -gt 365 ]; then
  err "--retention must be an integer in [1..365], got: ${RETENTION}"
  exit 1
fi

# Validate paths
CLEAN_PATHS=()
for p in "${PATHS[@]}"; do
  if [ -z "$p" ]; then
    err "empty --path argument"
    exit 1
  fi
  case "$p" in
    /) err "refusing --path /  (would tar the whole filesystem)"; exit 1 ;;
    /*) ;;
    *) err "--path must be absolute, got: ${p}"; exit 1 ;;
  esac
  # Strip trailing slash for consistency
  p="${p%/}"
  # Dedupe against already-collected paths
  case " ${CLEAN_PATHS[*]:-} " in
    *" ${p} "*) continue ;;
  esac
  if [ ! -e "$p" ]; then
    warn "path does not exist (will be skipped at backup time): ${p}"
  fi
  CLEAN_PATHS+=("$p")
done

# --- prereq checks ------------------------------------------------------
PREREQ_FAIL=0
check_cmd() {
  local cmd="$1" hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [ "$APPLY" = 1 ]; then
      err "missing prereq: ${cmd} (${hint})"
      PREREQ_FAIL=1
    else
      warn "missing prereq (would block --apply): ${cmd} (${hint})"
    fi
  fi
}
check_cmd age "apt install age"
check_cmd tar "always present on Debian"
require_systemd
[ "$APPLY" = 1 ] && [ "$PREREQ_FAIL" = 1 ] && exit 2

# --- print plan ---------------------------------------------------------
log "install plan (tag=${TAG}):"
log "  runner          : ${RUNNER}"
log "  systemd service : ${SVC_FILE}"
log "  systemd timer   : ${TIMER_FILE}     (daily 03:17 UTC ±10min, Persistent=true)"
log "  config dir      : ${ETC_DIR}"
log "  offsite env eg  : ${OFFSITE_EXAMPLE}"
log "  output dir      : ${OUT_DIR}        (mode 0700)"
log "  log file        : ${LOG_FILE}"
log "  recipient pubkey: ${RECIPIENT_FILE}    (operator must place; not generated here)"
log "  retention       : ${RETENTION} days (local + offsite)"
log "  paths backed up :"
for p in "${CLEAN_PATHS[@]}"; do log "    - ${p}"; done

# --- artifact templates -------------------------------------------------
gen_runner() {
  cat <<RUNNER_EOF
#!/bin/bash
# ${TAG}-backup — installed by harden-backup-skeleton.sh (devbox)
# Generic age-encrypted backup. Restore:
#   age -d -i <identity.txt> < <FILE>.tar.age | tar -xzf - -C /
set -euo pipefail

BACKUP_DIR="${OUT_DIR}"
RECIPIENT_FILE="${RECIPIENT_FILE}"
RETENTION_DAYS=${RETENTION}
OFFSITE_ENV="${OFFSITE_ENV}"
TAG="${TAG}"

mkdir -p "\$BACKUP_DIR"
chmod 700 "\$BACKUP_DIR"

if [[ ! -f "\$RECIPIENT_FILE" ]]; then
  echo "ERROR: recipient public key missing at \$RECIPIENT_FILE" >&2
  exit 1
fi
RECIPIENT="\$(cat "\$RECIPIENT_FILE")"

STAMP="\$(date -u +%Y%m%dT%H%M%SZ)"
OUT="\${BACKUP_DIR}/\${TAG}-\${STAMP}.tar.age"
TMP="\${OUT}.tmp"

# Paths are passed relative to / so 'tar -C /' works whether or not
# they exist; missing paths are silently skipped.
INCLUDE_PATHS=(
$(for p in "${CLEAN_PATHS[@]}"; do printf '  %q\n' "${p#/}"; done))

EXCLUDES=(
  --exclude=node_modules
  --exclude=.cache
  --exclude='*.log'
  --exclude=.npm
  --exclude=.bun/install/cache
)

# Stream tar -> age (no plaintext on disk).
tar -czf - "\${EXCLUDES[@]}" -C / "\${INCLUDE_PATHS[@]}" 2>/dev/null \\
  | age -r "\$RECIPIENT" -o "\$TMP"

mv "\$TMP" "\$OUT"
chmod 600 "\$OUT"

# Local retention
find "\$BACKUP_DIR" -name "\${TAG}-*.tar.age" -mtime "+\${RETENTION_DAYS}" -delete

# Off-site push (opt-in)
OFFSITE_STATUS="skipped"
if [[ -f "\$OFFSITE_ENV" ]]; then
  # shellcheck disable=SC1090
  source "\$OFFSITE_ENV"
  if [[ -n "\${REMOTE:-}" ]]; then
    if rclone copy "\$OUT" "\$REMOTE" --no-traverse 2>>"${LOG_FILE}"; then
      OFFSITE_STATUS="pushed_to_\${REMOTE}"
      rclone delete "\$REMOTE" --min-age "\${RETENTION_DAYS}d" --include "\${TAG}-*.tar.age" \\
        2>>"${LOG_FILE}" || true
    else
      OFFSITE_STATUS="push_failed_see_${LOG_FILE}"
    fi
  else
    # File present but REMOTE not set — surface the misconfig instead of silently skipping.
    OFFSITE_STATUS="env_present_but_REMOTE_unset"
  fi
fi

SIZE=\$(stat -c%s "\$OUT")
COUNT=\$(find "\$BACKUP_DIR" -name "\${TAG}-*.tar.age" | wc -l)
echo "\$(date -u +%FT%TZ) backup_ok size=\${SIZE}B file=\${OUT##*/} kept=\${COUNT} offsite=\${OFFSITE_STATUS}"
RUNNER_EOF
}

gen_service() {
  cat <<SVC_EOF
[Unit]
Description=Encrypted ${TAG} backup
After=network.target

[Service]
Type=oneshot
ExecStart=${RUNNER}
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
SVC_EOF
}

gen_timer() {
  cat <<TIMER_EOF
[Unit]
Description=Daily ${TAG} backup at 03:17 UTC

[Timer]
OnCalendar=*-*-* 03:17:00 UTC
RandomizedDelaySec=600
Persistent=true
Unit=${TAG}-backup.service

[Install]
WantedBy=timers.target
TIMER_EOF
}

gen_offsite_example() {
  cat <<OFFSITE_EOF
# ${TAG}-backup off-site push configuration (example).
#
# Copy to ${OFFSITE_ENV} (mode 0600, root:root) to enable
# off-site upload of the daily age-encrypted snapshot. Without this
# file the script keeps backups local-only.
#
# REMOTE format: <rclone-remote-name>:<bucket-or-path>
# Examples:
#   REMOTE=r2-${TAG}:${TAG}-backups/${TAG}    # Cloudflare R2
#   REMOTE=b2-${TAG}:my-bucket/${TAG}         # Backblaze B2
#   REMOTE=s3-${TAG}:my-bucket/${TAG}         # generic S3
#
# Recommended pattern (see docs/harden-modules.md):
#   - Dedicated bucket per service.
#   - Dedicated, bucket-scoped API token (Object Read+Write only).
#   - Per-service rclone config at /etc/${TAG}-backup/rclone.conf
#     (root:root 0600). Do not reuse ~/.config/rclone/rclone.conf.
#   - No double encryption (the .tar.age is already age-encrypted).
#
# Export RCLONE_CONFIG below so it reaches the rclone subprocess
# spawned by ${TAG}-backup.

#REMOTE=r2-${TAG}:${TAG}-backups/${TAG}
#export RCLONE_CONFIG=/etc/${TAG}-backup/rclone.conf
OFFSITE_EOF
}

# --- dry-run preview ----------------------------------------------------
if [ "$APPLY" = 0 ]; then
  echo
  log "----- runner preview (${RUNNER}) -----"
  gen_runner
  echo
  log "----- service preview (${SVC_FILE}) -----"
  gen_service
  echo
  log "----- timer preview (${TIMER_FILE}) -----"
  gen_timer
  echo
  log "dry-run complete. re-run with --apply to install."
  exit 0
fi

# --- apply --------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  err "--apply requires root."
  exit 1
fi

write_if_changed() {
  local target="$1" mode="$2" content="$3"
  if [ -f "$target" ] && printf '%s\n' "$content" | cmp -s - "$target"; then
    log "  unchanged: ${target}"
    return 0
  fi
  install -d -m 0755 "$(dirname "$target")"
  printf '%s\n' "$content" | install -m "$mode" /dev/stdin "$target"
  log "  wrote:     ${target} (mode ${mode})"
}

install -d -m 0700 "$OUT_DIR"
install -d -m 0755 "$ETC_DIR"
install -d -m 0700 "$(dirname "$RECIPIENT_FILE")"
touch "$LOG_FILE"
chmod 0640 "$LOG_FILE"

write_if_changed "$RUNNER"          0755 "$(gen_runner)"
write_if_changed "$SVC_FILE"        0644 "$(gen_service)"
write_if_changed "$TIMER_FILE"      0644 "$(gen_timer)"
write_if_changed "$OFFSITE_EXAMPLE" 0644 "$(gen_offsite_example)"

require_systemd
systemctl daemon-reload
systemctl enable --now "${TAG}-backup.timer"
log "timer enabled. next firing:"
systemctl list-timers "${TAG}-backup.timer" --no-pager | sed 's/^/  /'

if [ ! -f "$RECIPIENT_FILE" ]; then
  warn "recipient pubkey missing: ${RECIPIENT_FILE}"
  warn "  generate keypair (operator step):"
  warn "    install -d -m 0700 $(dirname "$RECIPIENT_FILE")"
  warn "    age-keygen -o $(dirname "$RECIPIENT_FILE")/identity.txt"
  warn "    chmod 600 $(dirname "$RECIPIENT_FILE")/identity.txt"
  warn "    grep '^# public key:' $(dirname "$RECIPIENT_FILE")/identity.txt | awk '{print \$4}' > ${RECIPIENT_FILE}"
  warn "    chmod 644 ${RECIPIENT_FILE}"
  warn "  then move identity.txt offsite (password manager + 2nd copy) and shred -u the local one."
fi

log "done. smoke-test:"
log "  ${RUNNER}    # expect: backup_ok size=...B file=${TAG}-...tar.age kept=1 offsite=skipped"
