# Atlas

Raspberry Pi 4B (Debian trixie, arm64) running a small self-hosted stack in Docker.
Remote access goes through a Cloudflare Tunnel and the WARP client (Zero Trust).
Nothing is published to the internet except what you explicitly add as a public hostname.

> Secrets are never stored in this file. Tokens and passwords live in each stack's
> `.env` (chmod 600, not in git) and in Proton Pass.

To build a new Atlas from scratch, follow [GUIDE.md](GUIDE.md).

## Layout

```
~/deploy/
├── arcane/        Arcane (Docker management UI)
├── caddy/         Caddy reverse proxy (TLS via Cloudflare DNS-01) + update.sh
├── cloudflared/   Cloudflare Tunnel connector + ssh-fwd forwarder
├── home-assistant/ Home Assistant (host network)
└── pihole/        Pi-hole + Unbound + mode.sh + unbound-update.sh
```

## Access model

- **SSH:** key-only, key stored in Proton Pass (Proton Pass SSH agent). Password auth is
  disabled via `/etc/ssh/sshd_config.d/01-hardening.conf` (it must sort before
  `50-cloud-init.conf`, which sets `PasswordAuthentication yes`).
- **Web UIs:** `https://<name>.atlas.fernandovideira.com` over WARP. These are *private
  hostname routes* on the Atlas tunnel, so they only resolve for WARP-enrolled devices.
- **LAN discovery:** `ssh fvideira@atlas.local` (avahi) works on the same LAN.

## Docker network

`cloudflare` (external, `172.18.0.0/16`) is shared by cloudflared, Caddy, Arcane, Pi-hole
and the SSH forwarder. `pihole_dns` (`172.31.53.0/24`) links Pi-hole and Unbound.

Private hostnames resolve for cloudflared through **Docker DNS network aliases**, so every
hostname needs an alias on the container that answers it (see Caddy and ssh-fwd).

## Services

| Stack | Container(s) | Notes |
|---|---|---|
| `cloudflared/` | `cloudflared`, `ssh-fwd` | Tunnel connector. `ssh-fwd` (alpine/socat) forwards `ssh.atlas...:22` to sshd on the host. |
| `caddy/` | `caddy` | Terminates TLS on 443 for private hostnames. Locally built image `caddy-cloudflare:local`. |
| `arcane/` | `arcane` | Docker UI. Root-equivalent access, keep it behind Access and its own login. No published ports. |
| `pihole/` | `pihole`, `unbound` | Pi-hole forwards to Unbound (`172.31.53.2`). Unbound is locally built (`unbound-local:latest`). |
| `home-assistant/` | `homeassistant` | `network_mode: host`, config in `/mnt/ssd/home-assistant`. |

### Hostnames (private hostname routes on the Atlas tunnel)

| Hostname | Goes to |
|---|---|
| `arcane.atlas.fernandovideira.com` | Caddy -> `arcane:3552` |
| `pihole.atlas.fernandovideira.com` | Caddy -> `pihole:80` (`/admin`) |
| `home.atlas.fernandovideira.com` | Caddy -> `host.docker.internal:8123` |
| `ssh.atlas.fernandovideira.com` | `ssh-fwd` -> host sshd :22 |

Adding a service: join it to the `cloudflare` network (no `ports:`), add its hostname as a
Caddy alias and a Caddyfile block, add a private hostname route on the tunnel, add it to the
Access policy.

## Scripts and scheduled jobs

### `caddy/update.sh` (monthly rebuild)

Rebuilds the Caddy image with `--pull --no-cache`, keeps `caddy-cloudflare:previous` as a
rollback, validates the Caddyfile, and rolls back on failure. Log: `caddy/update.log`.

### `pihole/unbound-update.sh` (monthly rebuild)

Same pattern for the Unbound image, plus a resolution check and a DNSSEC check
(`sigfail.verteiltesysteme.net` must return SERVFAIL). Log: `pihole/unbound-update.log`.

### `pihole/mode.sh` (Pi-hole bind address)

Pi-hole's DNS port binds to `${DNS_BIND}` from `pihole/.env`. The script updates it and
recreates the container (`docker compose up -d`).

| Mode | Behavior |
|---|---|
| `auto` / `home` | Wait up to 30 s for a private IP, bind to it, else fall back to `127.0.0.1`. Clears the pin. |
| `travel` | Bind to `127.0.0.1` and create `.pin-localhost`. |
| `sync` | Quiet check: only rebinds if the IP changed. Skipped while pinned. |

Log: `pihole/mode.log`.

### `backup/backup.sh` and `backup/offsite.sh` (nightly backups)

`backup.sh` writes local tarballs to `/mnt/ssd/backups` at 03:00 (root crontab). `offsite.sh`
pushes an encrypted restic snapshot to the Cloudflare R2 bucket `atlas-backup` at 03:15 (root
crontab), so a dead SSD no longer takes the backups with it. It keeps 7 daily, 4 weekly and
6 monthly snapshots; on Sundays it also prunes and checks 5% of the data. If `HC_URL` is set
it pings healthchecks.io (start, success, fail).
The script skips the upload and alerts when the repository would exceed 9.5 GiB, and alerts
above 8 GiB; both thresholds are variables (`CAP_GIB`, `WARN_GIB`) at the top of `offsite.sh`.

The restic password is stored in Proton Pass. Without it the backups are unreadable, so
never lose it.

One-time setup:

```bash
sudo apt install restic
sudo mkdir -p /root/.config/restic
sudo install -m 600 ~/deploy/backup/offsite.env.example /root/.config/restic/env
sudo nano /root/.config/restic/env             # fill in the values
sudo sh -c 'umask 077; cat > /root/.config/restic/password'   # paste the password, Ctrl-D
sudo -i
set -a; . /root/.config/restic/env; set +a; restic init
crontab -e                                      # as root, add the line below
```

```
15 3 * * * /home/fvideira/deploy/backup/offsite.sh
```

List snapshots and restore (as root, with the env loaded as above):

```bash
restic snapshots
restic restore latest --target /tmp/restore
```

Log: `/mnt/ssd/backups/offsite.log`.

### Cron (user `fvideira`)

```
PATH=/usr/local/bin:/usr/bin:/bin
0 4 1 * * /home/fvideira/deploy/caddy/update.sh
30 4 1 * * /home/fvideira/deploy/pihole/unbound-update.sh
```

View with `crontab -l`. Cron does not catch up if the Pi is off at 04:00.

### Cron (root)

```
PATH=/usr/local/bin:/usr/bin:/bin
0 3 * * * /home/fvideira/deploy/backup/backup.sh
15 3 * * * /home/fvideira/deploy/backup/offsite.sh
```

View with `sudo crontab -l`.

### systemd

Unit files are kept in `~/deploy/pihole/systemd/` and installed into `/etc/systemd/system/`.

- `pihole-mode.service` (oneshot at boot): runs `mode.sh auto`.
- Network change trigger, **use one of these, not both**:
  - `pihole-sync.service` + `pihole-sync.timer` (runs `mode.sh sync` every minute). Works with
    any network stack. This is the default choice.
  - `/etc/NetworkManager/dispatcher.d/90-pihole-bind` (runs `mode.sh sync` on `up` /
    `dhcp4-change`). Only works if NetworkManager manages the interface.

`mode.sh` takes a lock, so overlapping runs (boot service plus a trigger) are harmless.

Install:

```bash
mkdir -p ~/deploy/pihole/systemd
# put pihole-mode.service, pihole-sync.service and pihole-sync.timer there, then:
sudo cp ~/deploy/pihole/systemd/pihole-mode.service /etc/systemd/system/
sudo cp ~/deploy/pihole/systemd/pihole-sync.service ~/deploy/pihole/systemd/pihole-sync.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable pihole-mode.service
sudo systemctl enable --now pihole-sync.timer
```

Check status and logs:

```bash
systemctl status pihole-mode.service
systemctl list-timers pihole-sync.timer
journalctl -u pihole-mode.service -u pihole-sync.service --since today
tail -n 20 ~/deploy/pihole/mode.log
```

Run by hand:

```bash
sudo systemctl start pihole-mode.service      # same as mode.sh auto
~/deploy/pihole/mode.sh sync                  # quiet check
~/deploy/pihole/mode.sh travel                # pin to 127.0.0.1
~/deploy/pihole/mode.sh auto                  # back to normal, clears the pin
```

Disable or remove:

```bash
sudo systemctl disable --now pihole-sync.timer
sudo systemctl disable pihole-mode.service
sudo rm /etc/systemd/system/pihole-mode.service /etc/systemd/system/pihole-sync.service /etc/systemd/system/pihole-sync.timer
sudo systemctl daemon-reload
```

Alternative to the timer, the NetworkManager hook:

```bash
sudo tee /etc/NetworkManager/dispatcher.d/90-pihole-bind > /dev/null <<'EOF'
#!/bin/sh
case "$2" in
  up|dhcp4-change) ;;
  *) exit 0 ;;
esac
runuser -u fvideira -- env HOME=/home/fvideira /home/fvideira/deploy/pihole/mode.sh sync >/dev/null 2>&1 &
exit 0
EOF
sudo chown root:root /etc/NetworkManager/dispatcher.d/90-pihole-bind
sudo chmod 755 /etc/NetworkManager/dispatcher.d/90-pihole-bind
```

If you use the hook, disable the timer (command above), and the reverse.

## Firewall (ufw)

Default deny incoming. Docker-published ports bypass ufw, so publish nothing you don't want
on the LAN. Intended rules (verify with `sudo ufw status numbered`):

- 22/tcp from `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` (SSH; the Docker range lets
  `ssh-fwd` reach sshd)
- 8123/tcp from `172.18.0.0/16` (Caddy -> Home Assistant) and from the LAN ranges
- 21063:21070/tcp from the LAN ranges (HomeKit bridges)
- The old `10.71.71.0/24` and `192.168.1.0/24` rules should be deleted

## Cloudflare

- Tunnel: **Atlas Server** (token in `cloudflared/.env` as `TUNNEL_TOKEN`).
- Routes: the four private hostname routes above. Remove the `10.71.71.0/24` CIDR route
  and its Split Tunnel entry.
- Split Tunnels (Include mode) must contain `172.64.128.0/20` (added automatically).
- Access: one application restricting these hostnames to your email.
- Caddy's certificates use a scoped API token (`Zone:Read`, `DNS:Edit`) in `caddy/.env`.

## Moving to a new network (checklist)

1. SSH is allowed from all private ranges (not just the old subnet).
2. `atlas.local` resolves; the new router's device list is the fallback.
3. On the new router: DHCP reservation for the Pi, then set the router's DNS to the Pi
   after testing one device (`dig @<ip> example.com +short`).
4. Check `mode.log` / `docker ps`: Pi-hole must be bound to the new address.
5. Check the Docker subnets don't collide with the new LAN (`ip route`).
6. `docker logs cloudflared`: four `Registered tunnel connection` lines.

## Useful commands

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
sudo ufw status numbered
crontab -l
tail -n 30 ~/deploy/caddy/update.log
tail -n 30 ~/deploy/pihole/unbound-update.log
tail -n 30 ~/deploy/pihole/mode.log
dig @127.0.0.1 example.com +short                  # through Pi-hole
dig @10.71.71.112 sigfail.verteiltesysteme.net      # expect SERVFAIL
```

## Known issues and open items

- **Arcane update checker** reports errors for locally built images (`caddy-cloudflare:local`,
  `unbound-local:latest`). Cosmetic. The `com.getarcaneapp.arcane.updater=false` label may
  not suppress it.
- **Arcane version:** keep it at 1.13.0 or later (updater command injection fix).
- **Pi-hole listening mode** is `ALL`: never forward port 53 on the router or enable DMZ.
- **Unbound** uses a static trust anchor (`/usr/share/dns/root.key`), so keep the monthly
  rebuild running.
- **ssh-fwd** makes sshd log the forwarder's address instead of the client's.
