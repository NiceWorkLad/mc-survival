#!/bin/bash
# One-time setup for restic backups on game-server. Run with sudo from the repo checkout:
#   sudo bash scripts/setup-backups.sh
set -euo pipefail
cd "$(dirname "$0")/.."

apt-get install -y restic sqlite3 rsync

# Group that may read the (encrypted) repo so the PC can pull copies over SSH
groupadd -f mcbackup
usermod -aG mcbackup niceworklad

install -d -m 700 /etc/mc-backup
if [ ! -s /etc/mc-backup/restic-password ]; then
  openssl rand -base64 32 > /etc/mc-backup/restic-password
  chmod 600 /etc/mc-backup/restic-password
fi

install -d -m 750 /var/backups/minecraft /var/lib/mc-backup
if [ ! -f /var/backups/minecraft/restic/config ]; then
  RESTIC_PASSWORD_FILE=/etc/mc-backup/restic-password restic init --repo /var/backups/minecraft/restic
fi
chgrp mcbackup /var/backups/minecraft
chmod 750 /var/backups/minecraft
chgrp -R mcbackup /var/backups/minecraft/restic
chmod -R g+rX /var/backups/minecraft/restic
chmod g+w /var/backups/minecraft/restic/locks

install -m 755 scripts/mc-backup /usr/local/bin/mc-backup
install -m 644 systemd/mc-backup.service systemd/mc-backup.timer /etc/systemd/system/
systemctl daemon-reload

# Hand the PC a one-time copy of the password; mc-backup-pull deletes it after fetching
install -m 600 -o niceworklad -g niceworklad /etc/mc-backup/restic-password /home/niceworklad/restic-password.tmp

echo
echo "Done. Store this restic password in your password manager. Without it, no backup can be restored:"
cat /etc/mc-backup/restic-password
