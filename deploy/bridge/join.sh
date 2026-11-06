#!/usr/bin/env bash
# Joins this host to TalkChief Meet as an extra video bridge
# (RUNBOOK-bridge-node.md). Run as root on the NEW NODE from the unpacked bundle
# that scripts/bridge-bundle.sh wrote on the main host:
#
#   tar -xzf /root/bridge-<name>.tgz -C /root && /root/talkchief-meet-bridge/join.sh
#
# 1. Preflight: Docker with compose v2; this node owns BRIDGE_PRIVATE_IP and
#    the public JVB_ADVERTISE_IPS; sshd listens on no public or wildcard
#    address (SSH is never opened to the internet); the main host's Prosody
#    answers on MAIN_PRIVATE_IP:5222.
# 2. Pulls the jvb image and builds the node monitor from the bundle, before
#    the running bridge (if any) is touched.
# 3. If a jvb runs here and the bundle changes its settings, drains it first:
#    graceful shutdown (no new conferences; it exits when the last one ends),
#    waiting up to DRAIN_WAIT_MIN minutes (default 60). There is no override:
#    a bridge is replaced only once it is verifiably idle (stopped), checked
#    again right before the replacement. An unchanged bundle never restarts it.
# 4. Installs into /opt/talkchief-meet-bridge and enables
#    talkchief-meet-bridge-fw (only the main host may reach 8080 on the private
#    IP; docker.service then requires it) BEFORE the jvb publishes anything.
# 5. docker compose up, then requires /about/health, /colibri/stats and the
#    graceful-shutdown endpoint to answer.
#
# An upgrade that does not finish (failure or interruption after the drain)
# leaves $DEST/.upgrade-pending: the next run treats the bridge as changed and
# recreates it, even if the installed files already match the bundle. Any
# failure before the recreate also puts the previous .env and compose file back.
#
# Idempotent. SKIP_PUBLIC_IP_CHECK=1 skips only the public IP check. A broken
# bridge whose stats do not answer cannot be drained: stop it with
# `docker compose -f /opt/talkchief-meet-bridge/docker-compose.yml down`
# (Jicofo moves its meetings to another bridge), then re-run.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST=/opt/talkchief-meet-bridge
PROJECT=talkchief-meet-bridge
FW=/usr/local/sbin/talkchief-meet-fw
UNIT=talkchief-meet-bridge-fw.service
COLIBRI=http://127.0.0.1:8080
PENDING=$DEST/.upgrade-pending

die() { echo "join: $*" >&2; exit 1; }
ok() { echo "  ok: $*"; }
[ "$(id -u)" = 0 ] || die "run as root"
[ -f "$SRC/.env" ] && [ -f "$SRC/docker-compose.yml" ] || die "run join.sh from the unpacked bundle (it needs .env and docker-compose.yml next to it)"
envval() { grep -E "^$1=" "$SRC/.env" | tail -1 | cut -d= -f2- | tr -d '"'"'"'\r' || true; }
BRIDGE_PRIVATE_IP=$(envval BRIDGE_PRIVATE_IP)
PUBLIC_IP=$(envval JVB_ADVERTISE_IPS)
MAIN_PRIVATE_IP=$(envval MAIN_PRIVATE_IP)
XMPP_PORT=$(envval XMPP_PORT); XMPP_PORT=${XMPP_PORT:-5222}
NAME=$(envval BRIDGE_NAME)
for v in BRIDGE_PRIVATE_IP PUBLIC_IP MAIN_PRIVATE_IP NAME; do
  [ -n "${!v}" ] || die "$v is empty in the bundle's .env"
done

# Loopback, RFC 1918, IPv6 loopback, link-local and ULA: never the internet.
not_public() {
  local a=${1#[}; a=${a%]}; a=${a%%%*}
  case "$a" in
    127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|::1|fe80:*|fd*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "Preflight"
# Docker and compose v2.
command -v docker >/dev/null || die "Docker is not installed (Ubuntu: apt-get install -y docker.io docker-compose-v2)"
docker info >/dev/null 2>&1 || die "the Docker daemon is not running"
docker compose version >/dev/null 2>&1 || die "docker compose v2 is missing (Ubuntu: apt-get install -y docker-compose-v2)"
command -v iptables-restore >/dev/null || die "iptables is not installed"
ok "docker $(docker version -f '{{.Server.Version}}'), $(docker compose version --short)"

# This node owns its private IP.
local_ips=$(ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1)
grep -qxF "$BRIDGE_PRIVATE_IP" <<<"$local_ips" || die "BRIDGE_PRIVATE_IP $BRIDGE_PRIVATE_IP is not an address of this host (wrong bundle, or not on the private network yet)"
ok "private IP $BRIDGE_PRIVATE_IP"

# The public IP clients will be sent to is this node's. Hetzner's metadata
# service answers locally; no third-party lookup.
if [ "${SKIP_PUBLIC_IP_CHECK:-0}" = 1 ]; then
  echo "  SKIPPED: public IP check (SKIP_PUBLIC_IP_CHECK=1)"
else
  md=$(curl -fsS --max-time 3 http://169.254.169.254/hetzner/v1/metadata/public-ipv4 2>/dev/null || true)
  if [ "$md" = "$PUBLIC_IP" ] || grep -qxF "$PUBLIC_IP" <<<"$local_ips"; then
    ok "public IP $PUBLIC_IP"
  else
    die "JVB_ADVERTISE_IPS=$PUBLIC_IP is not this node's public IP (metadata says '${md:-nothing}'); wrong bundle? (SKIP_PUBLIC_IP_CHECK=1 to override)"
  fi
fi

# SSH must never be reachable from the internet: every sshd listener (by
# process, port 22, or a Port from sshd_config) must be on a private or
# loopback address, never 0.0.0.0, [::] or a public IP.
ssh_ports=$( { echo 22; sshd -T 2>/dev/null | awk 'tolower($1) == "port" {print $2}'; } | sort -u)
bad=""
while read -r _ _ _ laddr _ proc; do
  [ -n "${laddr:-}" ] || continue
  port=${laddr##*:}; addr=${laddr%:*}
  if grep -qxF "$port" <<<"$ssh_ports" || [[ ${proc:-} == *'"sshd"'* ]]; then
    not_public "$addr" || bad="$bad $laddr"
  fi
done < <(ss -Hltnp)
[ -z "$bad" ] || die "sshd listens on a public or wildcard address:$bad. Bind it to $BRIDGE_PRIVATE_IP only (ListenAddress, or ssh.socket ListenStream) before joining"
ok "sshd is not listening on any public or wildcard address"

# The main host's Prosody, over the private network.
timeout 5 bash -c "exec 3<>/dev/tcp/$MAIN_PRIVATE_IP/$XMPP_PORT" 2>/dev/null ||
  die "cannot reach Prosody at $MAIN_PRIVATE_IP:$XMPP_PORT. On the main host: is the one-time preparation done, and is $BRIDGE_PRIVATE_IP in /opt/talkchief-meet/bridges.allow (bridge-bundle.sh adds it)?"
ok "Prosody reachable at $MAIN_PRIVATE_IP:$XMPP_PORT"

# ── Helpers ──────────────────────────────────────────────────────────────
dc_src() { docker compose --project-directory "$SRC" -f "$SRC/docker-compose.yml" "$@"; }
dc() { (cd "$DEST" && docker compose "$@"); }
# jvb containers of this project that are running, restarting or paused.
live_jvb() {
  docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=jvb" \
    --filter status=running --filter status=restarting --filter status=paused
}
colibri_conferences() {
  curl -fsS --max-time 5 "$COLIBRI/colibri/stats" 2>/dev/null |
    python3 -c 'import json,sys; c=json.load(sys.stdin).get("conferences"); print(c if isinstance(c,int) and not isinstance(c,bool) and c>=0 else "")' 2>/dev/null || true
}
monitor_on() { case ",$(envval COMPOSE_PROFILES)," in *,monitor,*) return 0 ;; esac; return 1; }
same() { [ -f "$2" ] && cmp -s "$1" "$2"; }

# ── Pull and build first: nothing slow between the idle check and the start ──
echo "Pulling and building"
dc_src pull jvb
if monitor_on; then dc_src build monitor; fi

# The jvb's settings come from .env and docker-compose.yml only (local
# custom-jvb.conf tuning is kept and never compared).
jvb_changed=1; monitor_changed=1
if [ -f "$PENDING" ]; then
  echo "  a previous upgrade did not finish ($PENDING): the bridge will be recreated"
elif same "$SRC/.env" "$DEST/.env" && same "$SRC/docker-compose.yml" "$DEST/docker-compose.yml"; then
  jvb_changed=0
  if same "$SRC/monitor/Dockerfile" "$DEST/monitor/Dockerfile" && same "$SRC/monitor/monitor.py" "$DEST/monitor/monitor.py"; then
    monitor_changed=0
  fi
fi
live=$(live_jvb) || die "cannot ask Docker for this node's jvb containers"

# From here on an upgrade is in progress until the new bridge is verified.
if [ "$jvb_changed" = 1 ]; then
  install -d -m 0750 "$DEST"
  date -u +%FT%TZ >"$PENDING"
fi

# ── Drain the running bridge before it is replaced ───────────────────────
if [ -n "$live" ] && [ "$jvb_changed" = 1 ]; then
  echo "Draining the running bridge (the bundle changes its settings)"
  c=$(colibri_conferences)
  [ -n "$c" ] || die "the running bridge's $COLIBRI/colibri/stats does not answer, so it cannot be drained safely (see the header of this script)"
  cid=$(printf '%s\n' "$live" | head -1)
  policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid")
  # Otherwise Docker restarts the bridge as soon as the drained jvb exits.
  docker update --restart=no "$cid" >/dev/null
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H 'Content-Type: application/json' \
    -d '{"graceful-shutdown": "true"}' "$COLIBRI/colibri/shutdown" || true)
  if [ "$code" != 200 ]; then
    docker update --restart="${policy:-unless-stopped}" "$cid" >/dev/null || true
    die "graceful shutdown was refused (HTTP $code): needs SHUTDOWN_REST_ENABLED=true and COLIBRI_REST_ENABLED=true on the running bridge"
  fi
  ok "graceful shutdown started with $c conference(s); no new conferences come here"
  wait_min=${DRAIN_WAIT_MIN:-60}
  case "$wait_min" in ''|*[!0-9]*) die "DRAIN_WAIT_MIN must be a whole number of minutes" ;; esac
  deadline=$(( $(date +%s) + wait_min * 60 ))
  while :; do
    if ! live=$(live_jvb); then
      docker update --restart="${policy:-unless-stopped}" "$cid" >/dev/null || true
      die "cannot ask Docker whether the bridge is still running; not replacing it. Re-run join.sh"
    fi
    [ -n "$live" ] || break
    if [ "$(date +%s)" -ge "$deadline" ]; then
      # It keeps draining and exits when empty; let Docker bring it back then
      # with its current settings, so the node does not stay down.
      docker update --restart="${policy:-unless-stopped}" "$cid" >/dev/null || true
      die "the bridge still carries $(colibri_conferences || true) conference(s) after ${wait_min} min. It keeps draining and restarts with its current settings when empty; re-run join.sh later"
    fi
    echo "  waiting: $(colibri_conferences || true) conference(s) left on this bridge"
    sleep 15
  done
  ok "the bridge has stopped: idle"
fi

# Checked before anything in $DEST changes, and again right before the start.
if [ "$jvb_changed" = 1 ]; then
  live=$(live_jvb) || die "cannot ask Docker for this node's jvb containers; not replacing anything. Re-run join.sh"
  [ -z "$live" ] || die "a jvb is running (Docker restarted it, or someone started it): not replacing it. Re-run join.sh"
fi

echo "Installing into $DEST"
install -d -m 0750 "$DEST" "$DEST/config" "$DEST/config/jvb" "$DEST/config/jvb/custom-ca" "$DEST/monitor"
# Until the recreate has run, any failure puts the previous settings back
# (the pending marker stays, so the next run still recreates the bridge).
restore_previous() {
  local f
  for f in .env docker-compose.yml; do
    if [ -f "$DEST/$f.prev" ]; then mv -f "$DEST/$f.prev" "$DEST/$f"
    elif [ -f "$DEST/$f" ]; then mv -f "$DEST/$f" "$DEST/$f.rejected"; fi
  done
  echo "join: previous settings restored in $DEST" >&2
}
if [ "$jvb_changed" = 1 ]; then
  for f in .env docker-compose.yml; do
    if [ -f "$DEST/$f" ]; then cp -p "$DEST/$f" "$DEST/$f.prev"; fi
  done
  trap 'rc=$?; [ "$rc" = 0 ] || restore_previous' EXIT
fi
install -m 0600 "$SRC/.env" "$DEST/.env"
install -m 0644 "$SRC/docker-compose.yml" "$DEST/docker-compose.yml"
install -m 0644 "$SRC/VERSION" "$DEST/VERSION"
install -m 0755 "$SRC/join.sh" "$DEST/join.sh"
install -m 0644 "$SRC/monitor/Dockerfile" "$SRC/monitor/monitor.py" "$DEST/monitor/"
# Local JVB tuning survives a re-join.
if [ -f "$DEST/config/jvb/custom-jvb.conf" ]; then
  echo "  keeping the existing config/jvb/custom-jvb.conf"
else
  install -m 0644 "$SRC/config/jvb/custom-jvb.conf" "$DEST/config/jvb/custom-jvb.conf"
fi
# The Jitsi images run as uid/gid 1000.
chown -R 1000:1000 "$DEST/config"
chmod 755 "$DEST/monitor"

# Firewall first: 8080 on the private IP is published by the next step.
install -m 0755 "$SRC/scripts/meet-fw.sh" "$FW"
install -m 0644 "$SRC/$UNIT" "/etc/systemd/system/$UNIT"
"$FW" --role bridge enable
"$FW" --role bridge status

echo "Starting the bridge"
if [ "$jvb_changed" = 1 ]; then
  # Re-checked right before the replacement: no jvb may be running now.
  live=$(live_jvb) || die "cannot ask Docker for this node's jvb containers; not replacing it. Re-run join.sh"
  [ -z "$live" ] || die "a jvb is running again (Docker restarted it, or someone started it): not replacing it. Re-run join.sh"
  dc up -d --no-build --force-recreate --remove-orphans
  # The new settings are in use now: never roll the files back after this.
  trap - EXIT
  rm -f "$DEST/.env.prev" "$DEST/docker-compose.yml.prev" "$DEST/.env.rejected" "$DEST/docker-compose.yml.rejected"
else
  # Same settings: start whatever is not running, never replace the jvb.
  dc up -d --no-build --no-recreate --remove-orphans
  if [ "$monitor_changed" = 1 ] && monitor_on; then dc up -d --no-build --no-deps --force-recreate monitor; fi
fi

for _ in $(seq 1 45); do
  if curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:8080/about/health 2>/dev/null; then
    ok "jvb healthy (127.0.0.1:8080/about/health)"; break
  fi
  sleep 2
done
curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:8080/about/health 2>/dev/null || {
  dc logs --tail 60 jvb >&2 || true
  die "jvb did not become healthy within 90 s (logs above)"
}
# A bridge that cannot report its load or be drained must not stay unnoticed:
# both are needed by the runbook (and by the next join.sh) to replace it safely.
c=$(colibri_conferences)
[ -n "$c" ] || die "$COLIBRI/colibri/stats does not answer: the bridge needs COLIBRI_REST_ENABLED=true (.env). It is running but cannot be drained; see the header of join.sh"
ok "colibri stats answer ($c conference(s))"
# GET on the POST-only endpoint: 405 when it exists, 404 when it is disabled.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$COLIBRI/colibri/shutdown" || true)
case "$code" in
  404|000|'') die "$COLIBRI/colibri/shutdown is not available (HTTP ${code:-none}): the bridge needs SHUTDOWN_REST_ENABLED=true and COLIBRI_REST_ENABLED=true (.env). It is running but cannot be drained; see the header of join.sh" ;;
esac
ok "graceful shutdown endpoint present (GET answers HTTP $code)"
rm -f "$PENDING"

cat <<EOF

Bridge '$NAME' is up. Verify (RUNBOOK-bridge-node.md, "Verify"):
  here: curl -s 127.0.0.1:8080/colibri/stats | python3 -m json.tool | grep -E '"(conferences|participants|stress_level|graceful_shutdown|drain)"'
        docker compose -f $DEST/docker-compose.yml logs jvb | grep -iE 'muc|xmpp' | tail
  main: curl -s 127.0.0.1:8888/stats | python3 -c 'import json,sys; print(json.load(sys.stdin)["bridge_selector"])'
        (bridge_count and operational_bridge_count both go up by one)
Delete /root/bridge-$NAME.tgz and /root/talkchief-meet-bridge here and on the main host.
EOF
