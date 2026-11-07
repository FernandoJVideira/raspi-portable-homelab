#!/usr/bin/env bash
# Atlas off-site backup: encrypted restic snapshot of AppData, deploy and system config to Cloudflare R2.
# Runs as root (reads /etc/ufw and root crontabs). Config in /root/.config/restic/env (mode 600).
set -Eeuo pipefail

ENV_FILE="${RESTIC_ENV_FILE:-/root/.config/restic/env}"
DEST="/mnt/ssd/backups"
LOG="$DEST/offsite.log"
DEPLOY_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
APPDATA="/mnt/ssd/AppData"
WARN_GIB=8                                # alert when the repository is above this size
CAP_GIB=9.5                               # skip the upload if the repository would exceed this (R2 free tier: 10 GB)

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }

[ -f "$ENV_FILE" ] || { echo "Config $ENV_FILE not found, aborting" >&2; exit 1; }
case "$(stat -c %a "$ENV_FILE")" in
  600|400) ;;
  *) echo "Config $ENV_FILE must be mode 600 or 400, aborting" >&2; exit 1 ;;
esac
# shellcheck disable=SC1090
. "$ENV_FILE"
for v in RESTIC_REPOSITORY RESTIC_PASSWORD_FILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION; do
  [ -n "${!v:-}" ] || { echo "$v is empty in $ENV_FILE, aborting" >&2; exit 1; }
done
HC_URL="${HC_URL:-}"

# Never run if the data is on the SD card by accident
ssd_src="$(findmnt -no SOURCE -T /mnt/ssd || true)"
case "$ssd_src" in
  ""|/dev/mmcblk*) echo "/mnt/ssd is not on the SSD (source: '${ssd_src:-none}'), aborting" >&2; exit 1 ;;
esac

mkdir -p "$DEST"
chmod 700 "$DEST"

# One run at a time
exec 9>/run/lock/atlas-offsite.lock
flock -n 9 || exit 0

exec >>"$LOG" 2>&1

# Ping healthchecks.io; a failed ping never fails the backup
ping_hc() {
  [ -z "$HC_URL" ] || curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL$1" || true
}

echo "=== $(date -Is) offsite start ==="
trap 'echo "FAILED at $(date -Is) (line $LINENO)"; ping_hc /fail' ERR
ping_hc /start

# Only include paths that exist
paths=()
for p in "$APPDATA" "$DEPLOY_DIR" \
         /etc/ssh/sshd_config.d /etc/ufw /etc/docker/daemon.json /etc/fstab \
         /etc/systemd/system/pihole-mode.service /etc/systemd/system/pihole-sync.service \
         /etc/systemd/system/pihole-sync.timer /etc/NetworkManager/dispatcher.d/90-pihole-bind \
         /var/spool/cron/crontabs \
         /usr/local/bin/x735-fan.sh /usr/lib/systemd/system/x735-fan.service; do
  if [ -e "$p" ]; then paths+=("$p"); fi
done

opts=(--tag atlas --host atlas --one-file-system --exclude-caches
  --exclude 'home-assistant_v2.db*'
  --exclude '*.log' --exclude '*.log.*'
  --exclude "$APPDATA/home-assistant/deps"
  --exclude "$APPDATA/home-assistant/tts"
  --exclude "$APPDATA/home-assistant/backups"
  --exclude 'pihole-FTL.db*'
  --exclude '.*.lock')

# Repository size in bytes
repo_bytes() {
  restic stats --mode raw-data --json | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["total_size"]))'
}

# Fail like the ERR trap does, for non-zero exits that are handled by hand
fail() {
  echo "FAILED at $(date -Is): $1"
  ping_hc /fail
  exit "${2:-1}"
}

# Exit 3 means some files could not be read (a snapshot is still created); treat as a warning
repo_before="$(repo_bytes)"
rc=0
dry="$(restic backup --dry-run --json "${opts[@]}" "${paths[@]}")" || rc=$?
if [ "$rc" -eq 3 ]; then
  echo "warning: some files could not be read"
elif [ "$rc" -ne 0 ]; then
  fail "restic backup --dry-run exit $rc" "$rc"
fi
added="$(printf '%s\n' "$dry" | python3 -c '
import json, sys
for line in sys.stdin:
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get("message_type") == "summary":
        print(int(d["data_added"]))
        break
else:
    sys.exit(1)')"
echo "repo $((repo_before / 1048576)) MiB, tonight adds $((added / 1048576)) MiB"

over="$(python3 -c 'import sys; print(1 if (int(sys.argv[1]) + int(sys.argv[2])) / 2**30 > float(sys.argv[3]) else 0)' "$repo_before" "$added" "$CAP_GIB")"
if [ "$over" -eq 1 ]; then
  gib() { python3 -c 'import sys; print("%.2f" % (int(sys.argv[1]) / 2**30))' "$1"; }
  fail "size cap, repo $(gib "$repo_before") GiB + new $(gib "$added") GiB > cap $CAP_GIB GiB, upload skipped"
fi

rc=0
restic backup "${opts[@]}" "${paths[@]}" || rc=$?
if [ "$rc" -eq 3 ]; then
  echo "warning: some files could not be read"
elif [ "$rc" -ne 0 ]; then
  fail "restic backup exit $rc" "$rc"
fi

# Retention; prune and a partial integrity check only on Sundays
forget=(--tag atlas --host atlas --keep-daily 7 --keep-weekly 4 --keep-monthly 6)
if [ "$(date +%u)" -eq 7 ]; then
  restic forget "${forget[@]}" --prune
  restic check --read-data-subset=5%
else
  restic forget "${forget[@]}"
fi

echo "=== $(date -Is) offsite done ==="
repo_after="$(repo_bytes)"
warn="$(python3 -c 'import sys; print(1 if int(sys.argv[1]) / 2**30 > float(sys.argv[2]) else 0)' "$repo_after" "$WARN_GIB")"
if [ "$warn" -eq 1 ]; then
  echo "WARNING: repo $(python3 -c 'import sys; print("%.2f" % (int(sys.argv[1]) / 2**30))' "$repo_after") GiB above $WARN_GIB GiB"
  ping_hc /fail
else
  ping_hc ""
fi
tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
