# Survival server dashboard: Rails rebuild plan

This plan is meant to be built from by Claude, **one phase per session**. Each phase ends with a PR
and its acceptance checks ticked. Read all of section 0 before starting any phase.

Status: agreed with Louis on 30 Oct 2026. Items marked **(decide)** are still open.

---

## 0. Context and ground rules

### 0.1 What exists today
- **Server:** Paper 26.2 on the `game-server` VM (192.168.0.253, `ssh gameServers`), in `/opt/minecraft/survival`,
  running as the `minecraft` user under `minecraft-survival.service`. Console input goes through the FIFO
  `/run/minecraft-survival.stdin` (see `systemd/minecraft-survival.socket`).
- **Config repo:** `NiceWorkLad/mc-survival`, deployed with `sudo mc-deploy`. See the README.
- **Current dashboard:** `scripts/mc-dashboard`, a single Python file served on port 8200, LAN only, read-only.
  **It is the reference implementation for all parsing**: log line regexes, date handling across log rotation,
  session pairing (including crashes), player stats, Bedrock detection and daily activity. Port its logic and keep
  its edge cases. Don't reinvent them.
- **Backups:** `scripts/mc-backup` runs nightly at 04:30. It writes restic to `/var/backups/minecraft/restic`,
  with the password in `/etc/mc-backup/restic-password`.
- **Discord:** the EssentialsX Discord bot, plus `scripts/mc-leaderboard` (its categories are listed by `mc-leaderboard --list`).

### 0.2 Goals
1. Replace the Python dashboard with a Rails app that keeps **history**, and add admin tools for running the server.
2. Show deep technical stats (MSPT, GC, heap) clearly enough to make **informed tuning decisions**.
3. Make it a clean, tested, well-documented Rails project that also works as a portfolio piece.

### 0.3 Non-goals
- No public internet access. LAN only, never forwarded on the router.
- No editing plugin configs in the browser. Config changes go through git and `mc-deploy`.
- No LuckPerms editing. Permissions are changed in game, and the dashboard only displays them.

### 0.4 Hard rules (every phase)
- **The Rails app never runs as root, and never shells out to anything except `mc-ctl`** (section 0.7).
  Every privileged action is a fixed `mc-ctl` subcommand allowed in sudoers.
- **Everything technical or that changes something is behind the admin login.** Public (LAN, no login) pages are
  limited to the server status summary, players, activity, leaderboards and the map.
- **Every admin action is audited** (section 1.5), whether it succeeds or fails.
- **Destructive actions need a typed confirmation**, i.e. typing the server name. Restarts warn players first.
- Tests come with the code: parsers get fixtures cut from real logs, and actions get tests that stub `mc-ctl`.
- The Python dashboard keeps running on 8200 until Phase 2 is accepted.

### 0.5 Stack
- Rails 8 (current stable), Ruby (current stable), **SQLite** (WAL), **Solid Queue** with recurring jobs,
  **Solid Cable**, **Hotwire** (Turbo Streams + Stimulus), Propshaft + importmap.
- Auth: the Rails 8 authentication generator. There's only one or a few admin users, with no sign-up page.
  Admins are created with `bin/rails admin:create`.
- Charts: Chartkick + Chart.js (importmap). CSS: Tailwind **(decide: Tailwind or plain CSS)**.
- Tests: Minitest + fixtures, plus a GitHub Actions workflow that runs `bin/rails test` and RuboCop
  (rubocop-rails-omakase).
- Serving: Puma behind Thruster, with Solid Queue running inside Puma (`SOLID_QUEUE_IN_PUMA=1`).

### 0.6 Where things live
| Thing | Location |
|---|---|
| Rails app repo | new repo `NiceWorkLad/mc-dashboard` (Louis creates it; this plan becomes its `PLAN.md`) |
| App on the server | `/opt/mc-dashboard`, run by user `mcdash` |
| Service | `mc-dashboard-web.service`, port **8210**, LAN only (ufw from 192.168.0.0/24) |
| Database | `/var/lib/mc-dashboard/*.sqlite3` (backed up by `mc-backup`) |
| Server-side helpers, unit, sudoers, ufw rule | `mc-survival` repo (`scripts/`, `systemd/`, `sudoers/`), installed by `mc-deploy` |
| Secrets (`SECRET_KEY_BASE`, RCON, management secret, Discord alert channel) | `/opt/mc-dashboard/.env`, mode 600, owned by `mcdash` |

### 0.7 Data sources and access
| Data | Source | How the app reads it |
|---|---|---|
| Online status, version, player sample | Server list ping on 127.0.0.1:25565 | Ruby socket (port of `ping()`) |
| Players, allowlist, ops, bans, system messages, join/leave push events | **Minecraft Server Management Protocol** (JSON-RPC 2.0 over WebSocket, on localhost only) | `MgmtClient` with Bearer `MANAGEMENT_SERVER_SECRET`. **Check the method names with `rpc.discover` before coding against them.** |
| TPS, MSPT (avg/p95/max), per-collector GC, server CPU | **spark** (built into Paper), via `spark tps`, `spark health --memory`, `spark gc` | RCON on 127.0.0.1:25575; strip `§` codes; parse |
| Heap pools, GC counts and time (exact numbers) | `jstat -gc <pid>` | `mc-ctl metrics --json` (it must run as `minecraft`) |
| Process RSS/CPU, load, RAM, swap, disk, world size | `/proc`, `statvfs`, `du` | `mc-ctl metrics --json` |
| Events (joins, chat, deaths, advancements, restarts, Discord chat) | `logs/latest.log` + `logs/*.log.gz` | Read-only via ACL; incremental import |
| Player stats and advancements | `world/players/stats/*.json`, `world/players/advancements/*.json` | Read-only via ACL |
| Names / UUIDs | `usercache.json` | Read-only via ACL |
| Login/logout times | `plugins/Essentials/userdata/*.yml` | Read-only via ACL |
| mcMMO levels | `plugins/mcMMO/flatfile/` | Read-only via ACL (check the format against a real file) |
| Claims | `plugins/GriefPreventionData/ClaimData/` | Read-only via ACL (check the format) |
| Backups | restic | `mc-ctl backups --json` |
| Config drift / deploy | `mc-deploy --check` / `mc-deploy --yes` | `mc-ctl deploy-check`, `mc-ctl deploy` |
| Installed jars vs pins | `plugins/*.jar` sha256 vs `plugins.txt` | `mc-ctl jars --json` |

**Why this split (answer to 2.2):** spark gives the game-side numbers (TPS, tick time percentiles) that only the
server knows. `jstat` gives exact JVM numbers without asking the game thread for anything, and without fragile text
parsing. The management protocol gives structured JSON for players and access lists, plus push notifications, so
access management doesn't depend on parsing console text.

**The `mc-ctl` contract:** one root-owned script, `/usr/local/bin/mc-ctl`, allowed via
`mcdash ALL=(root) NOPASSWD: /usr/local/bin/mc-ctl`. Every subcommand validates its arguments strictly
(player names `^\.?[A-Za-z0-9_]{1,16}$`, snapshot IDs `^[0-9a-f]{8,64}$`, and so on), prints JSON when given
`--json`, and exits with 0 for ok, 1 for refused and 2 for a usage error. Subcommands are added in the phase
that needs them.

---

## 1. Foundation (Phase 1)

- **1.1 Admin login.** Use the Rails 8 auth generator with `User(role: admin)`. Public pages need no login. Technical,
  log, control, access, backup, plugin, test and alert pages need an admin. Rate-limit login (Rails `rate_limit`).
  Sessions expire after 7 days.
- **1.2 Layout.** Top nav with Overview, Players, Activity, Leaderboards, Map, and, for admins, Performance, Logs,
  Control, Access, Backups, Plugins, Test server. Light/dark theme following the system setting, with a toggle
  remembered in a cookie. It must work at phone width.
- **1.3 Live updates.** Jobs broadcast Turbo Streams (`broadcasts_refreshes` / targeted replaces) to the overview,
  players-online and activity feed. Nothing polls.
- **1.4 Background collection.** Solid Queue recurring jobs (section 13) write to SQLite, and pages read the database,
  never the server files directly. Data imports are idempotent.
- **1.5 Audit log.** `AuditEntry(user, action, params:json, result: ok/refused/error, exit_status, output_excerpt, ip)`.
  An admin-only page lists entries with filters by action and date.

**Acceptance:** an admin can log in and out; public pages work without login; admin pages redirect to login;
an audit entry is written for login; CI is green.

---

## 2. Overview (Phase 2 + Phase 3)

- **2.1 Status card (public):** online/offline, version, players online/max with avatars, uptime since the last start, MOTD.
- **2.2 Performance now (admin):** TPS (1m/5m/15m), MSPT (avg/p95/max over the last minute), with colours
  green < 40 ms, amber 40–50, red > 50 ms p95.
- **2.3 Machine and JVM (admin):**
  - Process: RSS, CPU % (process and system), thread count.
  - JVM: heap used/committed/max, old-gen use %, metaspace.
  - GC: young and old collections per minute and ms per minute, plus the longest pause in the last hour.
  - Host: load (1/5/15), RAM used/total, swap used, disk used/free, world size, size of the restic repo.
- **2.4 Health strip (admin):** last backup (ok/failed, age), Bedrock/NetherNet signaling up, config drift
  (from the last `deploy-check`), test server status, and jar pins all matching.
- **2.5 Quick actions (admin):** restart (with a countdown if players are online), broadcast message, back up now,
  and a link to **Backups → Restore** (section 8).
- **2.6 Tuning hints (admin):** rule-based, each showing the numbers that triggered it and linking to the chart. For example:
  - old-gen GC more than 2 per 10 min, or heap after GC above 80% of max → "heap is tight: consider raising `-Xmx` (VM has headroom: X GB free)"
  - heap after GC below 30% and RAM is tight → "heap is oversized"
  - MSPT p95 above 50 ms for 5+ minutes → "lag: run a spark profile" (with a button, section 5.4)
  - swap in use above 0 for 10+ minutes → "the VM is swapping"
  - disk above 85% → "disk nearly full"

  Thresholds live in one config file so they're easy to tune.

**Acceptance:** status matches the Python dashboard; every number on the card has a source in section 0.7; hints
fire in tests with fixture metric samples.

---

## 3. Players (Phase 2)

- **3.1 List (public):** online first, then by last seen. Shows play time, last seen, sessions, and op/banned badges
  (badges admin only).
- **3.2 Profile (public):** stats (play time, deaths, mob kills, distance, blocks mined, advancements), session list,
  deaths with causes, recent advancements, mcMMO levels and claim count. Admins also see first join and UUID.
- **3.3 Edition badge:** Bedrock if the UUID starts `00000000-0000-0000-` or the name starts with `.` (Floodgate prefix).
- **3.4 Stat history:** a daily snapshot of each player's stats JSON, with charts per stat (week/month), e.g. diamonds mined
  and hours played per week.
- **3.5 Leaderboards (public):** pick a category (the same set as `mc-leaderboard --list`), for all time or the last 7/30 days.
  Gains are computed from the snapshots.
- **3.6 Avatars:** head images cached locally in `storage/` (fetched once per day per player), with a placeholder for
  Bedrock players and for when the fetch fails.

**Acceptance:** for the same server state, player totals match `mc-dashboard --dump` exactly (check this with a script).

---

## 4. Activity (Phase 2)

- **4.1 Feed (public):** joins, leaves, deaths, advancements, chat (in game and Discord) and server start/stop, updating live.
- **4.2 Filters:** by type and player, plus text search. Paginated.
- **4.3 History:** stored in `events`, so it survives log rotation. On first run, import every existing `.log.gz`.
- **4.4 Hours per day:** 30-day chart of player-hours and distinct players (port of `daily`).
- **4.5 Heatmap:** busiest hour × weekday over the last 30/90 days.

**Acceptance:** importing the same logs twice creates no duplicates; a crash (start without stop) closes sessions the way
the Python `sessions()` does; the feed updates within 60 s of a join.

**Phase 2 done = parity with the Python dashboard → retire `mc-dashboard.service` and remove its ufw rule.**

---

## 5. Performance and logs (Phase 3, admin)

- **5.1 Charts:** TPS, MSPT p95, heap after GC, GC ms/min, CPU, RSS and players online, over 24 h / 7 d / 30 d / 90 d.
  Players online is overlaid on the other charts so load and lag can be compared.
- **5.2 Live log:** tail of `latest.log` over Turbo Streams, with filters (all / warnings / errors / a plugin name) and
  a pause button. Secrets are never shown: mask anything that matches the `.env` values.
- **5.3 Markers:** restarts, crashes, deploys and backups drawn as vertical lines on every chart.
- **5.4 Spark profile button:** runs `spark profiler start --timeout 120` via RCON and stores the viewer link it returns.
  A note on the button says the profile is uploaded to spark's public viewer.

**Retention:** 1-minute samples are kept for 7 days and 15-minute rollups (avg/max) for 90 days. A daily prune job handles this.

---

## 6. Server control (Phase 5, admin)

- **6.1 Start / stop / restart.** These call `mc-ctl start|stop|restart [--delay 60]`. A restart with players
  online warns them at 60 s and 10 s (the same as `mc-deploy`). Stop needs typed confirmation.
- **6.2 Console.** A text field that sends one command via RCON, with the output shown and audited. Commands in a
  blocklist (`stop`, `restart`, `op`, `deop`, `reload`) are refused with a pointer to the proper button.
- **6.3 Broadcast.** Sends an in-game system message via the management protocol.
- **6.4 Scheduled restarts.** An optional daily time (default off), which skips or delays while players are online
  (configurable), with the same warnings.

---

## 7. Access management (Phase 5, admin)

- **7.1 Allowlist:** list, add and remove. Bedrock players are added with their `.` name (Floodgate).
- **7.2 Ops:** list, add and remove, with typed confirmation to add.
- **7.3 Bans:** list with reason/date, and unban.
- **7.4 LuckPerms groups:** read-only view from `luckperms/permissions.txt` in mc-survival (already exported every 3 h).

All of this goes through the management protocol, with no editing of the JSON files directly.

---

## 8. Backups and restore (Phase 4, restore-to-test in Phase 8, admin)

- **8.1 Snapshots:** list (date, tag, size, files), last run result and duration, next scheduled run. Uses `mc-ctl backups --json`.
- **8.2 Back up now:** `mc-ctl backup-now`, which runs `mc-backup.service` and shows its progress.
- **8.3 World download:** link and the time of the last build.
- **8.4 PC copy:** how old the newest snapshot copied to the PC is (read from a status file the PC pull writes back) **(decide: worth it?)**.
- **8.5 Restore:**
  - **To test server (default):** `mc-ctl restore --to test <snapshot>`. Safe. Use it to inspect an old world
    or recover items.
  - **To production:** `mc-ctl restore --to prod <snapshot>`. Before restoring it (1) refuses if players are
    online unless forced, (2) **takes a fresh "pre-restore" snapshot first**, (3) stops the server, (4) restores
    world, playerdata and plugin data (not config, which comes from git), (5) starts it and checks it came up.
    It needs typed confirmation and shows exactly what will be replaced and how old the snapshot is.
  - **Single-player restore:** restore one player's inventory/stats/advancements files from a snapshot while
    they are offline. Useful after a bad death or grief. **(decide: include?)**

---

## 9. Plugins and config (Phase 6, admin)

- **9.1 Jars:** installed jar vs `plugins.txt`, showing version and sha256 ✓/✗, plus unknown jars that aren't pinned.
- **9.2 Config drift:** the output of `mc-ctl deploy-check` as a rendered diff. It runs hourly and on demand.
- **9.3 Deploy:** shows the diff, then a confirm button runs `mc-ctl deploy` (non-interactive `mc-deploy --yes`)
  and offers the restart from section 6.1.
- **9.4 Update checker:** daily check of Modrinth / GeyserMC / Paper APIs for newer versions, as a list only.
  It never auto-updates.

---

## 10. Test server (Phase 8, admin)

This depends on the `mcctl` work agreed earlier: a test server in `/opt/minecraft/test` on the `testing` branch,
ports 25566 / 19142 / 19143, with the four-way split of config, environment settings, state and binaries.

- **10.1 Status:** up/down, branch and commit, players, and RAM.
- **10.2 Actions:** **Clone prod → test**, **Reset test** (from backup or blank) and **Promote test → prod**
  (with a health check and automatic rollback). Each one maps to an `mc-ctl test …` subcommand that wraps `mcctl`.
- **10.3 Diff:** `testing` vs `main` (from GitHub's compare API or a local git fetch) shown before promoting.

---

## 11. Map and extras (Phase 7)

- **11.1 Map (public):** BlueMap embedded (iframe to port 8100) with a link to open it full-screen.
- **11.2 Bedrock (admin):** Geyser version, transport, signaling up, advertised address (from `geyser nethernet
  advertised` via RCON), and Bedrock players online.
- **11.3 Discord (admin):** bridge connected (from the log), leaderboard preview and a "post now" button
  (`mc-leaderboard --dry-run` / run).

---

## 12. Alerts (Phase 7, admin)

- **12.1 Discord alerts** to a separate admin channel (`DISCORD_ALERT_CHANNEL`) using the existing bot token:
  server down for more than 2 min, backup failed or more than 30 h old, disk above 85%, MSPT p95 above 50 ms for 5+ min,
  NetherNet signaling down, and config drift for more than 24 h.
- Each alert fires once, then sends a "resolved" message. Alerts can be muted per type for N hours. All of it is shown
  on an alerts page.

---

## 13. Data model and jobs

### Tables
- `users` (from the generator) + `role`
- `players` (uuid PK-ish, name, bedrock, first_seen_at, last_seen_at)
- `player_sessions` (player_id, started_at, ended_at, ended_by: leave/stop/crash, open)
- `events` (occurred_at, kind, player_id null, source game/discord/server, text, `dedupe_key` unique =
  sha1 of occurred_at+kind+name+text)
- `log_imports` (filename, inode, byte_offset, imported_at): so `latest.log` is read incrementally and each `.gz` only once
- `player_stat_snapshots` (player_id, taken_on, stats:json) unique (player_id, taken_on)
- `metric_samples` (taken_at, resolution 1m/15m, tps_1m, mspt_avg, mspt_p95, mspt_max, heap_used, heap_committed,
  heap_max, old_gen_pct, gc_young_count, gc_young_ms, gc_old_count, gc_old_ms, gc_max_pause_ms, cpu_process,
  cpu_system, rss, threads, load1, ram_used, swap_used, disk_used, players_online)
- `audit_entries`, `alerts` (kind, state, fired_at, resolved_at, muted_until), `settings` (key/value)
- `spark_profiles` (url, started_by, started_at)

### Recurring jobs (`config/recurring.yml`)
| Job | Every | Does |
|---|---|---|
| `StatusJob` | 15 s | ping and broadcast the status card |
| `ImportLogsJob` | 30 s | import new log lines and update sessions |
| `CollectMetricsJob` | 1 min | spark via RCON + `mc-ctl metrics` → `metric_samples` |
| `HealthCheckJob` | 1 min | evaluate alerts and hints, update the health strip |
| `SnapshotStatsJob` | daily 04:00 + on player leave | player stats snapshots |
| `DeployCheckJob` | hourly | `mc-ctl deploy-check` |
| `UpdateCheckJob` | daily | plugin update check |
| `RollupAndPruneJob` | daily 03:30 | 1m → 15m rollups, apply retention |

---

## 14. Phases (build order)

Each phase is one PR in `mc-dashboard` (and, where noted, one in `mc-survival`).

- [ ] **Phase 0: server prep (mc-survival PR).** Create the `mcdash` user. Add read-only ACLs (with default ACLs
  so new files are covered) on `logs/`, `world/players/`, `usercache.json`, `plugins/Essentials/userdata/`,
  `plugins/mcMMO/flatfile/` and `plugins/GriefPreventionData/ClaimData/`. Enable RCON (with
  **`broadcast-rcon-to-ops=false`**, or ops get spammed every minute) and the management server on localhost
  (`management-server-port=25585`, TLS off since it's localhost only). Neither port goes in ufw. Add the first
  `mc-ctl` subcommands (`metrics`, `status`), a sudoers file, `mc-dashboard-web.service`, the ufw rule for 8210, and
  the dashboard DB in `mc-backup`.
  *Accept:* `sudo -u mcdash sudo mc-ctl metrics --json` works; `mcdash` can read the listed files and nothing else;
  RCON/management ports are not reachable from another LAN machine.
- [ ] **Phase 1: skeleton.** New app, auth, layout, theme, audit log, CI, deploy script (`bin/deploy`: pull, bundle,
  assets, migrate, restart). Section 1.
- [ ] **Phase 2: parity.** Data import, overview status (2.1), players (3.1–3.3, 3.6), activity (4.1–4.4).
  Run it side by side with the Python dashboard for a week, then retire the Python one. Then add 3.4, 3.5 and 4.5.
- [ ] **Phase 3: performance.** Sections 2.2–2.4, 2.6 and 5.
- [ ] **Phase 4: backups.** Sections 8.1–8.3, 8.5 (production restore only, with every safeguard), and 2.5.
- [ ] **Phase 5: control and access.** Sections 6 and 7.
- [ ] **Phase 6: plugins and config.** Section 9.
- [ ] **Phase 7: extras and alerts.** Sections 11 and 12.
- [ ] **Phase 8: test server.** Write `mcctl` in mc-survival first, then section 10, plus restore-to-test (8.5).

---

## 15. Open decisions
- Tailwind or plain CSS (0.5).
- 8.4 PC copy status: worth adding a write-back from the PC?
- 8.5 single-player restore: include?
- Should the public pages show chat? (It's LAN only, but anyone on the Wi-Fi could read it.)

## 16. Instructions for Claude, per session
1. Read this file and the PR for the previous phase. Work only on the next unticked phase.
2. Never connect to or change the live server from the session. Server-side changes are PRs to `mc-survival`
   that Louis deploys with `mc-deploy`.
3. Get real sample files from Louis (a log excerpt, a stats JSON, `rpc.discover` output, `spark tps` output)
   before writing a parser, and turn them into fixtures. Redact IPs and anything secret.
4. Keep PRs reviewable: migrations, models + tests, then UI.
5. Finish by ticking the phase checkbox, listing anything deferred under section 15, and writing the manual
   test steps Louis needs to run on the server.
