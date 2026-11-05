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
# 2. Installs into /opt/talkchief-meet-bridge and enables
#    talkchief-meet-bridge-fw (only the main host may reach 8080 on the private
#    IP) BEFORE the jvb publishes anything.
# 3. docker compose pull + up, then waits for /about/health.
#
# Idempotent. When a jvb already runs here, a re-run (new bundle, new VERSION)
# refuses unless the bridge reports 0 conferences: drain it first (runbook) or
# set FORCE=1 to accept that its meetings move to another bridge.
# SKIP_PUBLIC_IP_CHECK=1 skips only the public IP check.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST=/opt/talkchief-meet-bridge
PROJECT=talkchief-meet-bridge
FW=/usr/local/sbin/talkchief-meet-fw
UNIT=talkchief-meet-bridge-fw.service

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

# A jvb already running here: only replace it when it carries no meetings.
if [ -f "$DEST/docker-compose.yml" ] && [ -n "$(cd "$DEST" && docker compose ps -q --status running jvb 2>/dev/null)" ]; then
  if [ "${FORCE:-0}" = 1 ]; then
    echo "  FORCE=1: replacing the running bridge even if it carries meetings"
  else
    c=$(curl -fsS --max-time 5 http://127.0.0.1:8080/colibri/stats 2>/dev/null |
      python3 -c 'import json,sys; c=json.load(sys.stdin).get("conferences"); print(c if isinstance(c,int) and not isinstance(c,bool) else "")' 2>/dev/null || true)
    [ "$c" = 0 ] || die "this bridge reports ${c:-unknown (stats unreadable)} conference(s): drain it first (RUNBOOK-bridge-node.md) or set FORCE=1"
    ok "running bridge has 0 conferences"
  fi
fi

echo "Installing into $DEST"
install -d -m 0750 "$DEST" "$DEST/config" "$DEST/config/jvb" "$DEST/config/jvb/custom-ca" "$DEST/monitor"
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
systemctl daemon-reload
systemctl enable "$UNIT" >/dev/null
systemctl restart "$UNIT"
"$FW" --role bridge status

echo "Starting the bridge"
cd "$DEST"
docker compose pull jvb
docker compose up -d --remove-orphans

for _ in $(seq 1 45); do
  if curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:8080/about/health 2>/dev/null; then
    ok "jvb healthy (127.0.0.1:8080/about/health)"; break
  fi
  sleep 2
done
curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:8080/about/health 2>/dev/null || {
  docker compose logs --tail 60 jvb >&2 || true
  die "jvb did not become healthy within 90 s (logs above)"
}

cat <<EOF

Bridge '$NAME' is up. Verify (RUNBOOK-bridge-node.md, "Verify"):
  here: curl -s 127.0.0.1:8080/colibri/stats | python3 -m json.tool | grep -E '"(conferences|participants|stress_level|graceful_shutdown|drain)"'
        docker compose -f $DEST/docker-compose.yml logs jvb | grep -iE 'muc|xmpp' | tail
  main: curl -s 127.0.0.1:8888/stats | python3 -c 'import json,sys; print(json.load(sys.stdin)["bridge_selector"])'
        (bridge_count and operational_bridge_count both go up by one)
Delete /root/bridge-$NAME.tgz and /root/talkchief-meet-bridge here and on the main host.
EOF
