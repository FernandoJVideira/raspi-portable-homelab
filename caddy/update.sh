#!/usr/bin/env bash
set -Eeuo pipefail

DIR="$HOME/deploy/caddy"
LOG="$DIR/update.log"
IMAGE="caddy-cloudflare:local"
BACKUP="caddy-cloudflare:previous"

cd "$DIR"

# Don't run twice at once
exec 9>"$DIR/.update.lock"
flock -n 9 || { echo "Already running" >&2; exit 0; }

exec >>"$LOG" 2>&1
echo "=== $(date -Is) caddy rebuild start ==="

rollback() {
  echo "FAILED at $(date -Is), rolling back"
  if docker image inspect "$BACKUP" >/dev/null 2>&1; then
    docker tag "$BACKUP" "$IMAGE"
    docker compose up -d --no-build --force-recreate || true
  fi
  tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  exit 1
}
trap rollback ERR

# Keep the current image as a rollback point
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker tag "$IMAGE" "$BACKUP"
fi

docker compose build --pull --no-cache
docker compose up -d

# Verify: container up, config valid
sleep 15
[ "$(docker inspect -f '{{.State.Running}}' caddy)" = "true" ]
docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

docker image prune -f >/dev/null   # dangling layers only
echo "=== $(date -Is) done ==="
tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
