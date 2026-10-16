# mc-survival

Configuration for the Paper survival server on `game-server` (192.168.0.253, `ssh gameServers`).
Server lives in `/opt/minecraft/survival`, runs as the `minecraft` user under systemd.

## Layout

| Path | Goes to on the server |
|---|---|
| `server/` | `/opt/minecraft/survival/` (server.properties, bukkit/spigot/paper configs) |
| `plugins/<Name>/` | `/opt/minecraft/survival/plugins/<Name>/` (config files only) |
| `plugins.txt` | Pinned server + plugin jars (versions, checksums, download pages) |
| `systemd/` | `/etc/systemd/system/` |
| `scripts/` | `/usr/local/bin/` |
| `secrets.env.example` | Template for `/opt/minecraft/secrets.env` (never committed) |

## What is deliberately *not* here

- **Secrets**: RCON password, management secret, Floodgate `key.pem`. `server.properties` uses `${VAR}` placeholders.
- **Jars**: pinned by version + sha256 in `plugins.txt`.
- **Runtime data**: worlds, player data, claims, WorldGuard regions, CoreProtect/LuckPerms databases,
  whitelist/ops/bans (changed in-game). These belong in backups.

## Changing config

Edit here, commit, push. Deploying to the server is manual for now (copy the file over and restart);
an `mc-deploy` script that pulls, substitutes secrets and restarts is planned.

Plugins rewrite their own configs on startup (adding comments, new defaults), so expect small diffs
when re-syncing from the live server.

## Backups

- **Server** (`scripts/mc-backup`, nightly 04:30): pauses saving only while the world and a
  consistent `sqlite3 .backup` of CoreProtect are copied to `/var/lib/mc-backup/stage`, then
  backs that up with restic to `/var/backups/minecraft/restic` (7 daily / 4 weekly / 6 monthly).
- **PC** (`pc/mc-backup-pull`, WSL): `restic copy` pulls new snapshots over SSH into
  `E:\MinecraftBackups\restic` (14 daily / 8 weekly / 12 monthly). Log: `~/.config/mc-backup/pull.log`.
- PC schedule: systemd user timer `pc/systemd/mc-backup-pull.timer` (every 3h while WSL runs, symlinked into `~/.config/systemd/user/`).
- One-time server setup: `sudo bash scripts/setup-backups.sh`.
- The restic password lives in `/etc/mc-backup/restic-password` (server) and
  `~/.config/mc-backup/restic-password` (PC). **Keep a copy in a password manager**: without it
  no backup can be restored.

Restore a snapshot (PC example):

    ~/.local/bin/restic -r /mnt/e/MinecraftBackups/restic snapshots
    ~/.local/bin/restic -r /mnt/e/MinecraftBackups/restic restore latest --target /tmp/mc-restore
