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

1. Edit here (or on GitHub), commit, push.
2. On the server: `sudo mc-deploy`. It pulls the repo into `~/mc-survival` (read-only deploy key),
   fills `${VAR}` placeholders from `/opt/minecraft/secrets.env`, shows a diff, asks, then installs:
   `server/` and `plugins/` into the server dir, `systemd/` into `/etc/systemd/system`, `scripts/mc-*`
   into `/usr/local/bin`. It never deletes files on the server.
3. If a restart is needed it says so, checks who's online, and warns players in chat 60s before.
   BlueMap-only changes just need `/bluemap reload` in game.

`sudo mc-deploy --check` shows differences without changing anything (exit 1 if there are any).
Missing secrets listed in `secrets.env.example` are generated automatically on first run.

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

## Live state back into git (PC)

- `pc/mc-pull-live` (timer every 3h): exports LuckPerms groups/permissions to `luckperms/permissions.txt`
  and commits + pushes when they change, so `/lp` edits get history. Change permissions in game, not in that file.
- `pc/mc-pull-live --configs`: copies live config files over the working tree (secrets stay as
  placeholders) so you can `git diff` what changed on the server, e.g. plugins rewriting their configs
  or edits made in game. Nothing is committed automatically.

## Web: map + world download (port 8100)

Caddy (`caddy/Caddyfile`, deployed to `/etc/caddy/` by `mc-deploy`) owns the public port 8100:
- `/world/`: nightly world download (`scripts/mc-worldzip`, run at the end of `mc-backup` from the
  same snapshot). Overworld + Nether + level.dat + map data; no player data, no End. Published
  atomically to `/var/www/world/`.
- everything else: reverse-proxied to BlueMap on `127.0.0.1:8101`.
