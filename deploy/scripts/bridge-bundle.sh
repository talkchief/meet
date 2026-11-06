#!/usr/bin/env bash
# Prepares a TalkChief Meet bridge node (RUNBOOK-bridge-node.md). Run as root on
# the MAIN meeting host, from the same deploy/ checkout install.sh ran from:
#
#   bridge-bundle.sh <node-private-ip> <node-public-ip> <node-name>
#
# 1. Checks the one-time main-host preparation is done (Prosody published on
#    the private IP, talkchief-meet-fw installed) and that the main host runs
#    the version in VERSION.
# 2. Renders bridge/env.bridge.template from /opt/talkchief-meet/.env and
#    VERSION and writes /root/bridge-<node-name>.tgz (mode 0600; it holds the
#    one bridge secret, JVB_AUTH_PASSWORD).
# 3. Adds the node's private IP to /opt/talkchief-meet/bridges.allow and
#    re-applies the 5222 allowlist (a reload: instant; neither Prosody nor
#    Docker is restarted).
#
# Re-running is safe: the tarball is rewritten, the allowlist entry is not
# duplicated. Copy the tarball to the node over the private network and run
# join.sh there. Env: OUT_DIR (default /root).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST=/opt/talkchief-meet
ENVF=$DEST/.env
ALLOW=$DEST/bridges.allow
OUT_DIR=${OUT_DIR:-/root}
FW=/usr/local/sbin/talkchief-meet-fw
UNIT=talkchief-meet-fw.service

die() { echo "bridge-bundle: $*" >&2; exit 1; }
[ $# -eq 3 ] || { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }
NODE_PRIV=$1 NODE_PUB=$2 NAME=$3
[ "$(id -u)" = 0 ] || die "run as root"

valid_ipv4() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    [[ $o =~ ^(0|[1-9][0-9]*)$ ]] && [ "$o" -le 255 ] || return 1
  done
}
# The Hetzner private network the meeting hosts share.
in_private_net() { valid_ipv4 "$1" && [[ $1 == 10.1.* ]]; }
# A routable public IPv4: not RFC 1918, loopback, link-local, CGNAT,
# "this network", multicast or reserved.
is_public_ipv4() {
  valid_ipv4 "$1" || return 1
  local a b; IFS=. read -r a b _ _ <<<"$1"
  [ "$a" -eq 0 ] || [ "$a" -eq 10 ] || [ "$a" -eq 127 ] || [ "$a" -ge 224 ] && return 1
  [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 1
  [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 1
  [ "$a" -eq 169 ] && [ "$b" -eq 254 ] && return 1
  [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 1
  return 0
}
envval() { grep -E "^$1=" "$ENVF" | tail -1 | cut -d= -f2- | tr -d '"'"'"'\r' || true; }

# ── Arguments ────────────────────────────────────────────────────────────
in_private_net "$NODE_PRIV" || die "node private IP '$NODE_PRIV' must be an IPv4 address in 10.1.0.0/16"
is_public_ipv4 "$NODE_PUB" || die "node public IP '$NODE_PUB' must be a public IPv4 address"
[[ $NAME =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "node name '$NAME' must be lowercase letters, digits and '-', at most 31 characters"

# ── Main-host preparation (RUNBOOK-bridge-node.md, "One-time preparation") ──
[ -r "$ENVF" ] || die "$ENVF not found: run scripts/install.sh first"
MAIN_PRIV=$(envval PROSODY_C2S_BIND)
in_private_net "$MAIN_PRIV" || die "PROSODY_C2S_BIND is '${MAIN_PRIV:-unset (127.0.0.1)}': do the one-time main-host preparation first (Prosody published on the private IP)"
[ "$NODE_PRIV" != "$MAIN_PRIV" ] || die "the node's private IP is the main host's own"
[ "$NODE_PUB" != "$(envval JVB_ADVERTISE_IPS)" ] || die "the node's public IP is the main host's own"
(cd "$DEST" && docker compose port prosody 5222 2>/dev/null) | grep -qxF "$MAIN_PRIV:5222" ||
  die "Prosody 5222 is not published on $MAIN_PRIV: run scripts/install.sh (zero conferences) after setting PROSODY_C2S_BIND"
[ -x "$FW" ] && [ -f "/etc/systemd/system/$UNIT" ] || die "$UNIT is not installed: run scripts/install.sh from this checkout first"

# Lockstep: the bridge runs exactly the image version the main host runs.
# shellcheck source=../VERSION
source "$HERE/VERSION"
RUNNING_VERSION=$(envval JITSI_IMAGE_VERSION)
[ "$RUNNING_VERSION" = "$DJM_TAG" ] ||
  die "main host runs JITSI_IMAGE_VERSION=${RUNNING_VERSION:-unset} but VERSION says $DJM_TAG: upgrade the main host (install.sh) or use the matching checkout"

# Shards (RUNBOOK-shards.md): the bridge joins every shard's Prosody.
XMPP_SERVERS=$MAIN_PRIV
SHARD_IPS=""
if [ -f "$DEST/shards.list" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}; read -r ip _ <<<"$line" || true
    [ -n "${ip:-}" ] || continue
    in_private_net "$ip" || die "shards.list: '$ip' is not an address in 10.1.0.0/16"
    SHARD_IPS=${SHARD_IPS:+$SHARD_IPS,}$ip
  done <"$DEST/shards.list"
  [[ ",$SHARD_IPS," == *",$MAIN_PRIV,"* ]] || die "shards.list does not list this host ($MAIN_PRIV)"
  XMPP_SERVERS=$SHARD_IPS
fi

# ── Values for the template ──────────────────────────────────────────────
declare -A V=(
  [JITSI_IMAGE_REPO]=$(envval JITSI_IMAGE_REPO)
  [JITSI_IMAGE_VERSION]=$DJM_TAG
  [MAIN_PRIVATE_IP]=$MAIN_PRIV
  [XMPP_SERVERS]=$XMPP_SERVERS
  [SHARD_PRIVATE_IPS]=$SHARD_IPS
  [XMPP_AUTH_DOMAIN]=$(envval XMPP_AUTH_DOMAIN)
  [XMPP_INTERNAL_MUC_DOMAIN]=$(envval XMPP_INTERNAL_MUC_DOMAIN)
  [JVB_BREWERY_MUC]=$(envval JVB_BREWERY_MUC)
  [JVB_AUTH_USER]=$(envval JVB_AUTH_USER)
  [JVB_AUTH_PASSWORD]=$(envval JVB_AUTH_PASSWORD)
  [BRIDGE_NAME]=$NAME
  [NODE_PRIVATE_IP]=$NODE_PRIV
  [NODE_PUBLIC_IP]=$NODE_PUB
  [ENABLE_OCTO]=$(envval ENABLE_OCTO)
  [JVB_OCTO_REGION]=$(envval JVB_OCTO_REGION)
  [SENTRY_DSN]=$(envval TALKCHIEF_SENTRY_DSN)
)
# Upstream defaults for what the main host does not override.
[ -n "${V[JITSI_IMAGE_REPO]}" ] || V[JITSI_IMAGE_REPO]=ghcr.io/jitsi
[ -n "${V[XMPP_AUTH_DOMAIN]}" ] || V[XMPP_AUTH_DOMAIN]=auth.meet.jitsi
[ -n "${V[XMPP_INTERNAL_MUC_DOMAIN]}" ] || V[XMPP_INTERNAL_MUC_DOMAIN]=internal-muc.meet.jitsi
[ -n "${V[JVB_BREWERY_MUC]}" ] || V[JVB_BREWERY_MUC]=jvbbrewery
[ -n "${V[JVB_AUTH_USER]}" ] || V[JVB_AUTH_USER]=jvb
[ -n "${V[ENABLE_OCTO]}" ] || V[ENABLE_OCTO]=0
# The main monitor's DSN default lives in docker-compose.override.yml.
if [ -z "${V[SENTRY_DSN]}" ]; then
  V[SENTRY_DSN]=$(sed -n 's/.*SENTRY_DSN=\${TALKCHIEF_SENTRY_DSN:-\([^}]*\)}.*/\1/p' "$HERE/docker-compose.override.yml" | head -1)
fi
V[COMPOSE_PROFILES]=$([ -n "${V[SENTRY_DSN]}" ] && echo monitor || true)
[ -n "${V[JVB_AUTH_PASSWORD]}" ] || die "JVB_AUTH_PASSWORD missing from $ENVF"
# Values go into an unquoted compose .env: allow no spaces, quotes or "$".
for k in "${!V[@]}"; do
  [[ ${V[$k]} =~ ^[A-Za-z0-9._:/@,=+-]*$ ]] || die "$k from $ENVF has characters a compose .env cannot carry unquoted"
done

# ── Bundle ───────────────────────────────────────────────────────────────
umask 077
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
B=$WORK/talkchief-meet-bridge
mkdir -p "$B/config/jvb/custom-ca" "$B/monitor" "$B/scripts"
while IFS= read -r line || [ -n "$line" ]; do
  for k in "${!V[@]}"; do line=${line//"@$k@"/"${V[$k]}"}; done
  printf '%s\n' "$line"
done <"$HERE/bridge/env.bridge.template" >"$B/.env"
if grep -q '@[A-Z_]*@' "$B/.env"; then die "unfilled placeholder in the rendered .env: $(grep -o '@[A-Z_]*@' "$B/.env" | sort -u | tr '\n' ' ')"; fi
chmod 600 "$B/.env"
install -m 0644 "$HERE/bridge/docker-compose.yml" "$B/docker-compose.yml"
install -m 0644 "$HERE/bridge/custom-jvb.conf" "$B/config/jvb/custom-jvb.conf"
install -m 0644 "$HERE/bridge/talkchief-meet-bridge-fw.service" "$B/talkchief-meet-bridge-fw.service"
install -m 0755 "$HERE/bridge/join.sh" "$B/join.sh"
install -m 0755 "$HERE/scripts/meet-fw.sh" "$B/scripts/meet-fw.sh"
install -m 0644 "$HERE/monitor/Dockerfile" "$HERE/monitor/monitor.py" "$B/monitor/"
install -m 0644 "$HERE/VERSION" "$B/VERSION"
chmod 755 "$B" "$B/config" "$B/config/jvb" "$B/config/jvb/custom-ca" "$B/monitor" "$B/scripts"

mkdir -p "$OUT_DIR"
OUT=$OUT_DIR/bridge-$NAME.tgz
tar -czf "$OUT.part" -C "$WORK" talkchief-meet-bridge
chmod 600 "$OUT.part"
mv -f "$OUT.part" "$OUT"

# ── Allow the node to reach Prosody 5222 ─────────────────────────────────
touch "$ALLOW"; chmod 644 "$ALLOW"
if awk -v ip="$NODE_PRIV" '{sub(/#.*/, "")} $1 == ip {found=1} END {exit !found}' "$ALLOW"; then
  echo "$NODE_PRIV is already in $ALLOW"
else
  printf '%s  # %s, added %s\n' "$NODE_PRIV" "$NAME" "$(date -u +%F)" >>"$ALLOW"
fi
# Enables the unit (docker.service then requires it) and reloads the rules.
# Never `systemctl restart` it: that would restart Docker.
"$FW" --role main enable
"$FW" --role main status

cat <<EOF

Bundle: $OUT (0600; contains JVB_AUTH_PASSWORD)
Next, over the private network only (never a public address):
  scp $OUT root@$NODE_PRIV:/root/
  ssh root@$NODE_PRIV 'tar -xzf /root/bridge-$NAME.tgz -C /root && /root/talkchief-meet-bridge/join.sh'
Then on this host, in /opt/talkchief-meet/.env set MONITOR_BRIDGES (comma list,
now including $NODE_PRIV) and run: docker compose up -d monitor
Delete the tarball on both hosts once the node has joined.
EOF
if [ -n "$SHARD_IPS" ]; then
  echo
  echo "Shards: the bridge joins every shard ($SHARD_IPS). Before join.sh, add"
  echo "$NODE_PRIV to /opt/talkchief-meet/bridges.allow on EVERY other shard host and run"
  echo "'systemctl reload talkchief-meet-fw' there (join.sh checks each Prosody)."
fi
