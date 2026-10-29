#!/bin/bash
# Firewall for game-server. Run with sudo:  sudo bash scripts/setup-firewall.sh
# Safety net: unless /tmp/ufw-ok exists 3 minutes after enabling, ufw turns itself back off.
set -euo pipefail

LAN=192.168.0.0/24

ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing

ufw allow from "$LAN" to any port 22 proto tcp comment 'SSH, home network only'
ufw allow 25565/tcp comment 'Minecraft Java'
ufw allow 19132/udp comment 'Minecraft Bedrock (Geyser RakNet)'
ufw allow 19132/tcp comment 'Minecraft Bedrock (Geyser NetherNet signaling)'
ufw allow 19133/udp comment 'Minecraft Bedrock (Geyser NetherNet gameplay)'
ufw allow 8100/tcp  comment 'BlueMap web map'
ufw allow from "$LAN" to any port 8200 proto tcp comment 'Dashboard, home network only'

rm -f /tmp/ufw-ok
systemd-run --quiet --unit=ufw-rollback --on-active=180 \
  /bin/sh -c '[ -e /tmp/ufw-ok ] || ufw disable'

ufw --force enable
ufw status verbose
echo
echo "Rollback armed: ufw disables itself in 3 minutes unless /tmp/ufw-ok is created."
