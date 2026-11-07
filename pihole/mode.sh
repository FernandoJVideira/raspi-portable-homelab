#!/usr/bin/env bash
set -Eeuo pipefail

DIR="$HOME/deploy/pihole"
ENVFILE="$DIR/.env"
PIN="$DIR/.pin-localhost"
LOG="$DIR/mode.log"

# One run at a time (boot service, hook and timer can overlap)
exec 9>"$DIR/.mode.lock"
flock -n 9 || exit 0

log() {
  echo "$(date -Is) $*" >> "$LOG"
  tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

# Source IP of the default route (works for eth0 or wifi)
current_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
}

is_private() {
  [[ "$1" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]
}

saved_bind() {
  grep '^DNS_BIND=' "$ENVFILE" 2>/dev/null | cut -d= -f2 || true
}

set_bind() {
  local ip="$1"
  touch "$ENVFILE"
  grep -v '^DNS_BIND=' "$ENVFILE" > "$ENVFILE.tmp" || true
  echo "DNS_BIND=$ip" >> "$ENVFILE.tmp"
  chmod 600 "$ENVFILE.tmp"
  mv "$ENVFILE.tmp" "$ENVFILE"
  cd "$DIR"
  docker compose up -d
  log "bound to $ip"
  echo "Pi-hole DNS bound to $ip"
}

case "${1:-}" in
  travel)
    touch "$PIN"
    set_bind "127.0.0.1"
    ;;
  home|auto)
    rm -f "$PIN"
    for _ in $(seq 1 30); do
      ip="$(current_ip || true)"
      if [ -n "${ip:-}" ] && is_private "$ip"; then
        set_bind "$ip"
        exit 0
      fi
      sleep 1
    done
    log "no private IP after 30s, falling back to localhost"
    set_bind "127.0.0.1"
    ;;
  sync)
    # Quiet check for hooks/timers: only act on a real change
    [ -e "$PIN" ] && exit 0
    ip="$(current_ip || true)"
    if [ -z "${ip:-}" ] || ! is_private "$ip"; then exit 0; fi
    [ "$ip" = "$(saved_bind)" ] && exit 0
    set_bind "$ip"
    ;;
  *)
    echo "usage: $0 home|travel|auto|sync" >&2
    exit 1
    ;;
esac
