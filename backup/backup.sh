#!/usr/bin/env bash
# Atlas backup: compose files, .env files, Docker volumes, Home Assistant config, system config.
# Runs as root (reads /etc/ufw and Docker volumes). Writes dated folders to /mnt/ssd/backups.
set -Eeuo pipefail

DEST="/mnt/ssd/backups"
KEEP=14                                   # number of dated backups to keep
USER_HOME="/home/fvideira"
CONTAINERS=(caddy arcane pihole unbound cloudflared ssh-fwd homeassistant)
APPDATA="/mnt/ssd/AppData"
EXTRA_PATHS=()                            # extra absolute paths, e.g. a bind-mounted data dir

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$DEST/$STAMP"
LOG="$DEST/backup.log"

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }

# Never write backups onto the SD card by accident
ssd_src="$(findmnt -no SOURCE -T /mnt/ssd || true)"
case "$ssd_src" in
  ""|/dev/mmcblk*) echo "/mnt/ssd is not on the SSD (source: '${ssd_src:-none}'), aborting" >&2; exit 1 ;;
esac

mkdir -p "$DEST"
chmod 700 "$DEST"

# One run at a time
exec 9>"$DEST/.backup.lock"
flock -n 9 || exit 0

exec >>"$LOG" 2>&1
echo "=== $(date -Is) backup start ==="
trap 'echo "FAILED at $(date -Is) (line $LINENO)"; rm -rf "$OUT"' ERR

mkdir -p "$OUT"
chmod 700 "$OUT"

# tar exits 1 when a file changes while it is being read; treat that as a warning
safe_tar() {
  local rc=0
  tar "$@" || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "warning: some files changed during archiving"
    return 0
  fi
  return "$rc"
}

# 1. Compose files, Caddyfile, scripts, .env files
safe_tar -czf "$OUT/deploy.tgz" -C "$USER_HOME" \
  --exclude='*.log' --exclude='.*.lock' --exclude='pihole-FTL.db*' \
  deploy

# 2. App data bind-mounted by the containers (Home Assistant, Pi-hole, Caddy certificates, Arcane)
if [ -d "$APPDATA" ]; then
  safe_tar -czf "$OUT/appdata.tgz" -C /mnt/ssd \
    --exclude='home-assistant_v2.db*' \
    --exclude='*.log*' \
    --exclude='AppData/home-assistant/deps' \
    --exclude='AppData/home-assistant/tts' \
    --exclude='AppData/home-assistant/backups' \
    --exclude='pihole-FTL.db*' \
    AppData
fi

# 3. Docker volumes used by the containers (Caddy certificates, Arcane data, ...)
volumes="$(for c in "${CONTAINERS[@]}"; do
  docker inspect "$c" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null || true
done | sort -u)"
for v in $volumes; do
  docker run --rm -v "$v":/data:ro -v "$OUT":/backup busybox \
    tar czf "/backup/volume-$v.tgz" -C /data .
done

# 4. Extra paths
extra=()
for p in "${EXTRA_PATHS[@]}"; do
  if [ -e "$p" ]; then extra+=("${p#/}"); fi
done
if [ "${#extra[@]}" -gt 0 ]; then
  safe_tar -czf "$OUT/extra.tgz" -C / "${extra[@]}"
fi

# 5. System config
sys=()
for p in /etc/ssh/sshd_config.d /etc/ufw /etc/docker/daemon.json /etc/fstab \
         /etc/systemd/system/pihole-mode.service /etc/systemd/system/pihole-sync.service \
         /etc/systemd/system/pihole-sync.timer /etc/NetworkManager/dispatcher.d/90-pihole-bind; do
  if [ -e "$p" ]; then sys+=("${p#/}"); fi
done
safe_tar -czf "$OUT/system.tgz" -C / "${sys[@]}"

# 6. Crontabs and a Docker inventory
crontab -l -u fvideira > "$OUT/crontab-fvideira.txt" 2>/dev/null || true
crontab -l > "$OUT/crontab-root.txt" 2>/dev/null || true
{
  docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
  docker network ls
  docker volume ls
} > "$OUT/docker-inventory.txt" 2>&1 || true

# 7. Check every archive is readable, lock down permissions
for f in "$OUT"/*.tgz; do
  tar -tzf "$f" >/dev/null
done
chmod -R go-rwx "$OUT"
date -Is > "$DEST/last-success"

# 8. Keep the newest $KEEP backups
ls -1dt "$DEST"/20*-* 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -rf

echo "=== $(date -Is) done ($(du -sh "$OUT" | cut -f1)) ==="
tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
