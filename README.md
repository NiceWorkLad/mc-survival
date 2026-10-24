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

## Dashboard (port 8200, home network only)

`scripts/mc-dashboard` (run by `mc-dashboard.service`) serves a stats page at http://192.168.0.253:8200:
who's online, recent players, every player's stats (play time, deaths, distance, ...), hours played per
day, an activity feed (joins, deaths, advancements, chat, restarts) and machine stats. It reads the
server's own logs and player files plus a status ping, so no plugin or RCON is involved. It refuses
non-private client addresses, and ufw only opens 8200 to the LAN; don't forward it on the router.
`mc-deploy` restarts it when it changes. Check its data with `sudo -u minecraft mc-dashboard --dump`.

One-time setup on the server:

    sudo mc-deploy
    sudo systemctl enable --now mc-dashboard
    sudo ufw allow from 192.168.0.0/24 to any port 8200 proto tcp comment 'Dashboard, home network only'

## Discord

- **Chat bridge + feed**: EssentialsX Discord (`plugins/EssentialsDiscord/config.yml`). Chat both ways,
  plus joins, leaves, deaths, advancements and server start/stop, in channel `1563673107414122586`.
  Player messages are posted under the player's name and head (needs the bot's Manage Webhooks permission).
  Running console commands from Discord (`/execute`) is turned off.
- **Daily leaderboard**: `scripts/mc-leaderboard`, run by `mc-leaderboard.timer` at 19:00 UK time.
  Picks a random category (diamonds, distance, XP, animals bred, ...; `mc-leaderboard --list`), ranks
  what players gained over the last 7 days and posts the top 5 with the bot. Each run's totals are
  kept for 8 days in `/var/lib/mc-leaderboard/state.json`; the first run posts all-time totals.
  Preview without posting: `sudo -u minecraft mc-leaderboard --dry-run [--category xp]`.
- The bot token is `DISCORD_BOT_TOKEN` in `/opt/minecraft/secrets.env`. It can't be generated, so
  `mc-deploy` stops until it's there. To set or replace it:

      ssh -t gameServers 'read -rsp "Bot token: " t; echo; t=$(printf %s "$t" | tr -d "[:space:]"); [[ "$t" =~ ^[A-Za-z0-9_.-]{50,100}$ ]] || { echo "Not a bot token (${#t} characters), nothing saved"; exit 1; }; sudo sed -i "/^DISCORD_BOT_TOKEN=/d" /opt/minecraft/secrets.env; echo "DISCORD_BOT_TOKEN=$t" | sudo tee -a /opt/minecraft/secrets.env >/dev/null && echo "Token saved (${#t} characters)"'
