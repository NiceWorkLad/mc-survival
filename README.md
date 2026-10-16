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
