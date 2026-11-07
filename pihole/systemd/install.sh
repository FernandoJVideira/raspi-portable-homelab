#!/usr/bin/env bash
# Install the Pi-hole systemd units for the deploy user. Run with sudo from the deploy user's session.
set -Eeuo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo" >&2; exit 1; }
DEPLOY_USER="${SUDO_USER:?run with sudo}"
SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DEPLOY_DIR="$(cd "$SRC/../.." && pwd)"
UNITS=/etc/systemd/system

for u in pihole-mode.service pihole-sync.service; do
  sed -e "s|@USER@|$DEPLOY_USER|g" -e "s|@DEPLOY_DIR@|$DEPLOY_DIR|g" "$SRC/$u" > "$UNITS/$u"
done
install -m 644 "$SRC/pihole-sync.timer" "$UNITS/pihole-sync.timer"

systemctl daemon-reload
systemctl enable pihole-mode.service
systemctl enable --now pihole-sync.timer
systemctl restart pihole-mode.service

systemctl cat pihole-mode.service pihole-sync.service | grep -E '^(User|ExecStart)='
