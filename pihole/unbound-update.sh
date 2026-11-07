#!/usr/bin/env bash
set -Eeuo pipefail

DIR="$HOME/deploy/pihole"
LOG="$DIR/unbound-update.log"
IMAGE="unbound-local:latest"
BACKUP="unbound-local:previous"
UB_IP="172.31.53.2"

cd "$DIR"

# Don't run twice at once
exec 9>"$DIR/.unbound-update.lock"
flock -n 9 || { echo "Already running" >&2; exit 0; }

exec >>"$LOG" 2>&1
echo "=== $(date -Is) unbound rebuild start ==="

trim_log() { tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }

rollback() {
  echo "FAILED at $(date -Is), rolling back"
  if docker image inspect "$BACKUP" >/dev/null 2>&1; then
    docker tag "$BACKUP" "$IMAGE"
    docker compose up -d --no-build --force-recreate unbound || true
  fi
  trim_log
  exit 1
}
trap rollback ERR

# Keep the current image as a rollback point
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker tag "$IMAGE" "$BACKUP"
fi

docker compose build --pull --no-cache unbound

# Validate the new image's config before swapping it in
docker run --rm "$IMAGE" unbound-checkconf /etc/unbound/unbound.conf

docker compose up -d unbound
sleep 10
[ "$(docker inspect -f '{{.State.Running}}' unbound)" = "true" ]

# Functional checks through the Pi-hole container (it has the route to Unbound)
if [ "$(docker inspect -f '{{.State.Running}}' pihole 2>/dev/null)" = "true" ] \
   && docker exec pihole which dig >/dev/null 2>&1; then
  docker exec pihole dig @"$UB_IP" example.com +short +time=5 +tries=2 | grep -q .
  docker exec pihole dig @"$UB_IP" sigfail.verteiltesysteme.net +time=5 +tries=2 | grep -q SERVFAIL
  echo "resolution and DNSSEC checks passed"
else
  echo "pihole not running or has no dig, skipped resolution checks"
fi

docker image prune -f >/dev/null
echo "=== $(date -Is) done ==="
trim_log
