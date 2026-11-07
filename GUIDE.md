# Building Atlas from scratch

This guide is the ordered procedure to deploy the whole setup on a fresh Raspberry Pi 4B that
boots from a USB SSD. The [README](README.md) is the reference; this guide links to it instead
of repeating long explanations. Replace every `<placeholder>` with your own value, and take
secrets from your password manager. Never paste secrets into git.

If you are rebuilding from a backup instead of starting fresh, follow phases 1 to 4, then do
phase 5 (restore), then continue from phase 6.

## Phase 1. Hardware and operating system

1. Assemble the Pi 4B with the Geekworm X735 HAT (fan) and connect the Crucial SSD in its USB 3
   enclosure to a blue USB 3 port. Connect Ethernet. Do not insert an SD card.
2. The Pi 4 bootloader default `BOOT_ORDER` is `0xf41`: it tries the SD card, then USB. With no
   SD card inserted it boots from the SSD, so no change is needed. Recent Pi 4s boot from USB out
   of the box. If your Pi has ever booted from an SD card, update the bootloader first, from that
   SD card, and reboot:

   ```bash
   sudo rpi-eeprom-update -a
   sudo reboot
   ```

3. On your computer, open Raspberry Pi Imager and flash **Raspberry Pi OS Lite (64-bit)**
   (Debian 13 trixie) directly onto the SSD. In the OS customisation settings use:
   - A hostname, written `<hostname>` in this guide (this repo uses `atlas` as the example).
   - A username of your choice, written `<user>` in this guide.
   - SSH enabled, public-key authentication only (paste your public key).
   - Timezone `<your timezone>` (for example `Europe/London`).
   - Wi-Fi is optional. Ethernet is the primary link. With no Ethernet link the Pi falls back
     to Wi-Fi and gets a different IP.
4. Plug the SSD into the Pi and power it on. Log in over SSH:

   ```bash
   ssh <user>@<hostname>.local
   ```

5. Update the system:

   ```bash
   sudo apt update && sudo apt full-upgrade -y
   sudo reboot
   ```

## Phase 2. Network and router

1. In your router, create a DHCP reservation for the Pi so its IP never changes.
2. Do **not** point the router's DNS at the Pi yet. That happens in phase 12, after Pi-hole has
   been tested from one device.

## Phase 3. Data folders and the repository

Everything persistent lives under `/mnt/ssd`. On this install it is a plain directory on the
root filesystem (no separate partition and no fstab entry).

1. Create the data folders:

   ```bash
   sudo mkdir -p /mnt/ssd/AppData/{pihole,home-assistant,arcane,caddy/caddy_data,caddy/caddy_config}
   sudo mkdir -p /mnt/ssd/backups
   sudo chown -R $USER:$USER /mnt/ssd/AppData
   ```

   `/mnt/ssd/backups` stays owned by root; `backup.sh` sets mode 700 on it.

2. Fork the repository on GitHub (or clone it directly) and use your fork's URL. Replace `<you>`
   with your GitHub username:

   ```bash
   sudo apt install -y git
   git clone https://github.com/<you>/raspi-portable-homelab.git ~/deploy
   ```

## Phase 4. Docker

1. Install Docker CE from Docker's official apt repository for Debian:

   ```bash
   sudo apt install -y ca-certificates curl
   sudo install -m 0755 -d /etc/apt/keyrings
   sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
   sudo chmod a+r /etc/apt/keyrings/docker.asc
   sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOT
   Types: deb
   URIs: https://download.docker.com/linux/debian
   Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
   Components: stable
   Signed-By: /etc/apt/keyrings/docker.asc
   EOT
   sudo apt update
   sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
   ```

2. Let your user run Docker, then log out and back in so the group applies:

   ```bash
   sudo usermod -aG docker $USER
   ```

3. Create the external network that the stacks share. The pihole stack creates its own `dns`
   network (172.31.53.0/24) later:

   ```bash
   docker network create --subnet 172.18.0.0/16 cloudflare
   ```

## Phase 5. Restoring from a backup instead of starting fresh

Skip this phase on a brand new install. Do it after phase 4 and **before** starting any stack.

1. Install restic and put the config in place, exactly as in the README one-time setup
   ([backups section](README.md#backupbackupsh-and-backupoffsitesh-nightly-backups)). You need
   the R2 token, the repository URL and the restic password from your password manager:

   ```bash
   sudo apt install -y restic
   sudo mkdir -p /root/.config/restic
   sudo install -m 600 ~/deploy/backup/offsite.env.example /root/.config/restic/env
   sudo nano /root/.config/restic/env
   sudo sh -c 'umask 077; cat > /root/.config/restic/password'
   ```

2. Load the config, list the snapshots and restore. Do not run `restic init`, the repository
   already exists:

   ```bash
   sudo -i
   set -a; . /root/.config/restic/env; set +a
   restic snapshots
   restic restore latest --target / --include /mnt/ssd/AppData --include /home/<user>/deploy
   exit
   ```

   The Home Assistant history database (`home-assistant_v2.db`) and Pi-hole's query log are
   excluded from backups by design, so history starts empty after a restore. Configuration,
   integrations and devices are restored.

   This also restores the `.env` files, so you can skip the secrets in phase 7 (check them
   with `ls -la ~/deploy/*/.env`).

3. Check ownership with `ls -la /mnt/ssd/AppData/*`. Restic restores the original owners.
   Pi-hole and Home Assistant write some files as root inside their folders, so a blanket
   `chown` is not needed and would be wrong. Only fix a directory that was originally owned by
   your user and now is not.

Then continue with phase 6.

## Phase 6. SSH hardening

1. Create the drop-in:

   ```bash
   sudo tee /etc/ssh/sshd_config.d/01-hardening.conf > /dev/null <<'EOT'
   PasswordAuthentication no
   KbdInteractiveAuthentication no
   PubkeyAuthentication yes
   EOT
   sudo systemctl restart ssh
   ```

2. Warning: open a **second** SSH session and confirm you can log in before closing the
   current one. If the new session fails, fix the file from the first one.

## Phase 7. Fill in the .env files

Nothing personal is hardcoded in the repository: every stack reads its values from its own
`.env`, and the scripts derive the repo path and user from where they are checked out. The
variables are listed in the README ([Configuration (.env)](README.md#configuration-env)).
Throughout this guide `example.com` is a placeholder for your domain, and hostnames follow the
pattern `arcane.atlas.example.com`.

Skip this phase if you restored a backup of your own install in phase 5, since the `.env` files
came back with it. Otherwise copy each example, lock it down and fill it in. Take secrets from
your password manager:

```bash
cd ~/deploy
for s in arcane caddy cloudflared pihole home-assistant; do
  cp "$s/.env.example" "$s/.env"
  chmod 600 "$s/.env"
done
nano arcane/.env          # ENCRYPTION_KEY, JWT_SECRET, APP_URL (https://arcane.atlas.example.com)
nano caddy/.env           # CF_API_TOKEN, DOMAIN (atlas.example.com)
nano cloudflared/.env     # TUNNEL_TOKEN, DOMAIN (same value as in caddy/.env)
nano pihole/.env          # PIHOLE_PASSWORD, TZ; leave DNS_BIND empty, mode.sh manages it
nano home-assistant/.env  # TZ (for example Europe/London)
```

`DOMAIN` is the zone your private hostnames live under: the services answer at
`arcane.<DOMAIN>`, `pihole.<DOMAIN>`, `home.<DOMAIN>` and `ssh.<DOMAIN>`.

The Cloudflare side (tunnel, token scopes) is described in the README
([Cloudflare](README.md#cloudflare)). Create the tunnel and copy its token before this step.

## Phase 8. Start the stacks

Start them in this order. The `--build` flag only matters for pihole (builds `unbound-local`)
and caddy (builds `caddy-cloudflare:local`):

```bash
cd ~/deploy/pihole && docker compose up -d --build
cd ~/deploy/cloudflared && docker compose up -d
cd ~/deploy/caddy && docker compose up -d --build
cd ~/deploy/arcane && docker compose up -d
cd ~/deploy/home-assistant && docker compose up -d
```

## Phase 9. systemd units for Pi-hole

Run the installer as your normal user with sudo. It renders `pihole-mode.service` and
`pihole-sync.service` with your user name and the repo path, copies `pihole-sync.timer`,
enables both, and starts the mode service ([systemd](README.md#systemd)):

```bash
sudo ~/deploy/pihole/systemd/install.sh
```

Use the timer or the NetworkManager hook, not both. Enabling a unit does not run it, so the
installer restarts `pihole-mode.service` itself: until it has run, Pi-hole listens only on
127.0.0.1 (`DNS_BIND` is empty) and LAN clients get no DNS.

## Phase 10. Firewall

Default deny incoming, then allow the ranges listed in the README
([Firewall (ufw)](README.md#firewall-ufw)). Allow SSH **before** enabling the firewall:

```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
for r in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
  sudo ufw allow from "$r" to any port 22 proto tcp
  sudo ufw allow from "$r" to any port 8123 proto tcp
  sudo ufw allow from "$r" to any port 21063:21070 proto tcp
done
sudo ufw allow from 172.18.0.0/16 to any port 8123 proto tcp
sudo ufw enable
sudo ufw status numbered
```

Docker-published ports bypass ufw, so publish nothing you do not want on the LAN.

## Phase 11. X735 fan

1. Install Geekworm's service:

   ```bash
   git clone https://github.com/geekworm-com/x735-script ~/x735-script
   cd ~/x735-script && sudo ./install-fan-service.sh
   ```

2. Add this line under `[all]` in `/boot/firmware/config.txt`, then reboot:

   ```
   dtoverlay=pwm-2chan,pin2=13,func2=4
   ```

3. Install `gpiod` (it provides `gpiomon`, and Lite may not have it), then check the service
   and the fan tachometer:

   ```bash
   sudo apt install -y gpiod
   systemctl status x735-fan
   n=$(timeout 2 gpiomon -c gpiochip0 -e falling -b pull-up 16 | wc -l); echo "~$((n*60/4)) RPM"
   ```

## Phase 12. Cloudflare, router DNS and cron

1. Finish the Cloudflare setup (the four private hostname routes, the Access application and
   WARP) as described in the README ([Cloudflare](README.md#cloudflare)). Check that the
   tunnel is healthy.
2. Test Pi-hole from one device, then point the router's DNS at the Pi. Pi-hole binds to the
   Pi's IP automatically through `mode.sh`:

   ```bash
   dig @<pi-ip> example.com +short
   ```

3. Install the user cron jobs with `crontab -e`, exactly as in the README
   ([Cron (user)](README.md#cron-user)):

   ```
   PATH=/usr/local/bin:/usr/bin:/bin
   0 4 1 * * /home/<user>/deploy/caddy/update.sh
   30 4 1 * * /home/<user>/deploy/pihole/unbound-update.sh
   ```

4. Install the root cron jobs with `sudo crontab -e`, as in the README
   ([Cron (root)](README.md#cron-root)). Add the `offsite.sh` line only after phase 13:

   ```
   PATH=/usr/local/bin:/usr/bin:/bin
   0 3 * * * /home/<user>/deploy/backup/backup.sh
   ```

## Phase 13. Off-site backups

On a restored install restic is already set up (phase 5); skip to step 4. Otherwise, in order:

1. In Cloudflare R2, create the bucket `atlas-backup`.
2. Create a bucket-scoped API token with **Object Read & Write** on that bucket only, and note
   the account ID, access key and secret.
3. Create a check on healthchecks.io and copy its ping URL (optional, but it alerts you when a
   night fails). Store the restic password in your password manager before you use it.
4. Follow the one-time setup in the README
   ([backups section](README.md#backupbackupsh-and-backupoffsitesh-nightly-backups)): install
   restic, create the env file and the password file, run `restic init`.
5. Add the root cron line `15 3 * * * /home/<user>/deploy/backup/offsite.sh` with
   `sudo crontab -e`.

## Phase 14. Verify

Work through this checklist. Replace `<pi-ip>` with the Pi's address.

1. The root filesystem is the SSD: `findmnt /` shows `/dev/sda2`.
2. `docker ps` shows seven containers: `unbound`, `pihole`, `cloudflared`, `ssh-fwd`, `caddy`,
   `arcane` and `homeassistant`, with `pihole` healthy.
3. Pi-hole resolves: `dig @<pi-ip> example.com +short` returns an address.
4. Pi-hole blocks: `dig @<pi-ip> doubleclick.net +short` returns `0.0.0.0`.
5. Home Assistant answers:

   ```bash
   curl -s -o /dev/null -w "%{http_code}" http://<pi-ip>:8123/
   ```

   It must print `200`.
6. `docker logs cloudflared` shows four `Registered tunnel connection` lines.
7. `systemctl --failed` is empty. `NetworkManager-wait-online` may fail; that is harmless.
8. The fan spins: repeat the RPM check from phase 11.
9. First backups. Run both by hand as root and read the logs:

   ```bash
   sudo /home/<user>/deploy/backup/backup.sh
   sudo /home/<user>/deploy/backup/offsite.sh
   sudo tail -n 20 /mnt/ssd/backups/backup.log /mnt/ssd/backups/offsite.log
   ```

   `backup.log` must end with a `done` line and `offsite.log` with `offsite done`, and
   `restic snapshots` (as root with the env loaded) must list the new snapshot.

When everything passes, Atlas is ready. Day-to-day commands and known issues are in the README
([Useful commands](README.md#useful-commands)).
