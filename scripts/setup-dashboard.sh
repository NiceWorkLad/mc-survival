#!/bin/bash
# One-time (and safe to re-run) setup for the Rails dashboard on game-server. Run with sudo
# from the repo checkout, *before* the mc-deploy that installs mc-ctl and the sudoers file:
#   sudo bash scripts/setup-dashboard.sh           create mcdash, dirs, .env, ACLs, ufw rule
#   sudo bash scripts/setup-dashboard.sh --check   only check that the access is right
#
# File access is deny-by-default. mcdash gets an explicit "no access" ACL entry on everything
# in the server dir except the paths it needs. A named-user entry wins over the "other"
# permission bits, so world-readable files (server.properties holds the RCON password) stay
# closed to it. Default ACLs make new files inherit the same rule: new log files are readable,
# a new plugin's config isn't. Re-run this after restoring files from a backup, because
# restic and rsync don't restore ACLs.
set -euo pipefail
cd "$(dirname "$0")/.."

U=mcdash
MC=/opt/minecraft
LIVE=$MC/survival
APP=/opt/mc-dashboard
DATA=/var/lib/mc-dashboard
SECRETS=$MC/secrets.env
LAN=192.168.0.0/24
PORT=8210

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 2; }
CHECK=0
case "${1:-}" in --check) CHECK=1 ;; "") ;; *) echo "usage: setup-dashboard.sh [--check]"; exit 2 ;; esac

# --- Access rules ------------------------------------------------------------
# Readable trees (files r, dirs r-x, inherited by new files)
READ=(
  "$LIVE/logs"
  "$LIVE/world/players"
  "$LIVE/usercache.json"
  "$LIVE/plugins/Essentials/userdata"
  "$LIVE/plugins/mcMMO/flatfile"
  "$LIVE/plugins/GriefPreventionData/ClaimData"
)
# Directories mcdash may pass through but not list; everything else in them is closed to it.
# Keys are fenced dirs, values the children left open (granted above, or fenced themselves).
declare -A FENCE=(
  ["$MC"]="survival"
  ["$LIVE"]="logs world usercache.json plugins"
  ["$LIVE/world"]="players"
  ["$LIVE/plugins"]="Essentials mcMMO GriefPreventionData"
  ["$LIVE/plugins/Essentials"]="userdata"
  ["$LIVE/plugins/mcMMO"]="flatfile"
  ["$LIVE/plugins/GriefPreventionData"]="ClaimData"
)

fence() { # $1=dir  $2=children to leave alone
  local dir=$1 keep=" $2 " child name
  setfacl -m "u:$U:--x" -m "d:u:$U:---" "$dir"
  for child in "$dir"/* "$dir"/.[!.]*; do
    [ -e "$child" ] && [ ! -L "$child" ] || continue
    name=${child##*/}
    [[ "$keep" == *" $name "* ]] && continue
    setfacl -m "u:$U:---" "$child"
  done
}

grant() { # $1=file or tree
  [ -e "$1" ] || { echo "  (missing, skipped: $1; re-run once it exists)"; return 0; }
  setfacl -R -m "u:$U:rX" "$1"
  [ -d "$1" ] && find "$1" -type d -exec setfacl -m "d:u:$U:rX" {} +
  return 0
}

# --- Checks ------------------------------------------------------------------
fails=0
as_u() { runuser -u "$U" -- "$@" >/dev/null 2>&1; }
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
can()  { if as_u test -r "$1"; then pass "can read $1"; else fail "cannot read $1"; fi; }
cant() { # files: open them; dirs: list them
  [ -e "$1" ] || { pass "(absent) $1"; return 0; }
  local how=(head -c1); [ -d "$1" ] && how=(ls)
  if as_u "${how[@]}" "$1"; then fail "CAN read $1"; else pass "cannot read $1"; fi
}
first() { find "$1" -maxdepth 1 -type f 2>/dev/null | head -1; }

check() {
  echo "Files mcdash should read:"
  can "$LIVE/logs/latest.log"
  can "$LIVE/usercache.json"
  for d in world/players/stats world/players/advancements plugins/Essentials/userdata \
           plugins/mcMMO/flatfile plugins/GriefPreventionData/ClaimData; do
    if f=$(first "$LIVE/$d") && [ -n "$f" ]; then can "$f"; else can "$LIVE/$d"; fi
  done
  echo "Files mcdash must not read:"
  for f in "$MC" "$LIVE" "$SECRETS" "$LIVE/server.properties" "$LIVE/ops.json" "$LIVE/whitelist.json" \
           "$LIVE/world/level.dat" "$LIVE/world/region" "$LIVE/plugins/EssentialsDiscord/config.yml" \
           "$LIVE/plugins/CoreProtect/database.db" "$LIVE/plugins/LuckPerms" \
           "$LIVE/plugins/Essentials/config.yml" /etc/mc-backup/restic-password \
           /var/backups/minecraft/restic/config; do
    cant "$f"
  done
  echo "sudo:"
  if out=$(runuser -u "$U" -- sudo -n /usr/local/bin/mc-ctl metrics --json 2>&1) \
     && printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["host"] else 1)'; then
    pass "sudo mc-ctl metrics --json gives JSON"
    jvm=$(printf '%s' "$out" | python3 -c 'import json,sys; j=json.load(sys.stdin)["jvm"]; print("server not running" if j is None else j.get("error", ""))')
    [ -z "$jvm" ] && pass "jstat heap/GC numbers present" || fail "no JVM numbers: $jvm"
  else
    fail "sudo mc-ctl metrics --json (has mc-deploy installed mc-ctl and sudoers/mc-dashboard?): ${out:0:200}"
  fi
  if as_u sudo -n /bin/true; then fail "mcdash can sudo other commands"; else pass "mcdash cannot sudo anything else"; fi
  echo "Ports (must not be open in ufw; the LAN test is in the README):"
  for p in 25575 25585; do
    if ufw status | grep -qE "^$p(/tcp)?\b"; then fail "ufw has a rule for $p"; else pass "no ufw rule for $p"; fi
  done
  if ss -Hltn "sport = :25585" | grep -qvE '127\.0\.0\.1:|\[::1\]:'; then fail "management server listens beyond localhost"
  elif ss -Hltn "sport = :25585" | grep -q .; then pass "management server on localhost only"
  else fail "management server not listening on 25585 (deployed and restarted?)"; fi
  if ufw status | grep -qE "^$PORT/tcp +ALLOW +$LAN"; then pass "ufw allows $PORT from $LAN"; else fail "no ufw rule for $PORT from $LAN"; fi
  echo
  [ "$fails" -eq 0 ] && echo "All checks passed." || { echo "$fails check(s) failed."; return 1; }
}

if [ "$CHECK" -eq 1 ]; then check; exit; fi

# --- Setup -------------------------------------------------------------------
command -v setfacl >/dev/null || apt-get install -y acl
if ! command -v jstat >/dev/null; then
  echo "NOTE: jstat is missing, so mc-ctl metrics can't report heap or GC. Install the JDK matching"
  echo "      the server's Java (java -version), e.g.  sudo apt-get install openjdk-25-jdk-headless"
fi

id "$U" >/dev/null 2>&1 || useradd --system --user-group --home-dir "$DATA" --shell /usr/sbin/nologin "$U"
install -d -o "$U" -g "$U" -m 750 "$APP" "$DATA"
install -d -o "$U" -g "$U" -m 700 "$DATA/backup"

# App secrets. The RCON and management secrets are copied from the server's secrets.env.
if [ ! -s "$APP/.env" ]; then
  get() { grep -E "^$1=" "$SECRETS" | head -1 | cut -d= -f2-; }
  rcon=$(get RCON_PASSWORD); mgmt=$(get MANAGEMENT_SERVER_SECRET)
  [ -n "$rcon" ] && [ -n "$mgmt" ] || { echo "RCON_PASSWORD / MANAGEMENT_SERVER_SECRET missing from $SECRETS: run sudo mc-deploy --check first"; exit 1; }
  umask 077
  cat > "$APP/.env" <<ENV
SECRET_KEY_BASE=$(openssl rand -hex 64)
RCON_HOST=127.0.0.1
RCON_PORT=25575
RCON_PASSWORD=$rcon
MANAGEMENT_SERVER_URL=ws://localhost:25585
MANAGEMENT_SERVER_SECRET=$mgmt
ENV
  chown "$U:$U" "$APP/.env"; chmod 600 "$APP/.env"
  echo "wrote $APP/.env"
fi

echo "Setting ACLs for $U:"
for dir in "$MC" "$LIVE" "$LIVE/world" "$LIVE/plugins" "$LIVE/plugins/Essentials" \
           "$LIVE/plugins/mcMMO" "$LIVE/plugins/GriefPreventionData"; do
  [ -d "$dir" ] && fence "$dir" "${FENCE[$dir]}"
done
for p in "${READ[@]}"; do grant "$p"; done

ufw allow from "$LAN" to any port "$PORT" proto tcp comment 'Dashboard (Rails), home network only' >/dev/null
echo "ufw: $PORT open to $LAN"

echo
echo "Done. Next: sudo mc-deploy (installs mc-ctl, sudoers, the unit; restarts the server for RCON),"
echo "then: sudo bash scripts/setup-dashboard.sh --check"
