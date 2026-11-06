#!/usr/bin/env bash
# Prepares a new TalkChief Meet shard host (RUNBOOK-shards.md). Run as root on
# an EXISTING shard (normally the first one, 10.1.0.44), from the same deploy/
# checkout install.sh ran from:
#
#   shard-bundle.sh <new-private-ip> <new-public-ip> <new-name>
#
# 1. Checks this host is already in shard mode (shards.list + host.env) and
#    runs the version in VERSION.
# 2. Adds the new shard to /opt/talkchief-meet/shards.list (this host's copy;
#    the same file must then be copied to every shard).
# 3. Writes /root/shard-<new-name>.tgz (mode 0600): this deploy/ checkout,
#    the shared secrets (this host's .env, jwt/private.pem, the TLS and TURN
#    certificates), bridges.allow, shards.list and a host.env for the new
#    host. All shards share the JWT key (Cowork signs once for every shard),
#    the XMPP component passwords (bridges log in to every shard) and the TURN
#    secret; install.sh never regenerates a secret that exists.
#
# Copy the tarball to the new host over the private network only, then run
# its shard-join.sh there. Delete it on both hosts afterwards.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST=/opt/talkchief-meet
OUT_DIR=${OUT_DIR:-/root}

die() { echo "shard-bundle: $*" >&2; exit 1; }
[ $# -eq 3 ] || { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }
NEW_PRIV=$1 NEW_PUB=$2 NAME=$3
[ "$(id -u)" = 0 ] || die "run as root"

valid_ipv4() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do [[ $o =~ ^(0|[1-9][0-9]*)$ ]] && [ "$o" -le 255 ] || return 1; done
}
in_private_net() { valid_ipv4 "$1" && [[ $1 == 10.1.* ]]; }
envval() { grep -E "^$1=" "$DEST/.env" | tail -1 | cut -d= -f2- | tr -d '"'"'"'\r' || true; }
hostval() { grep -E "^$1=" "$DEST/host.env" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

in_private_net "$NEW_PRIV" || die "new private IP '$NEW_PRIV' must be in 10.1.0.0/16"
valid_ipv4 "$NEW_PUB" && ! in_private_net "$NEW_PUB" || die "new public IP '$NEW_PUB' must be a public IPv4 address"
[[ $NAME =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "name '$NAME': lowercase letters, digits and '-', at most 31 characters"

[ -f "$DEST/shards.list" ] && [ -f "$DEST/host.env" ] ||
  die "this host is not in shard mode yet (RUNBOOK-shards.md, 'One-time preparation'): create $DEST/host.env and $DEST/shards.list, then run install.sh"
SELF=$(hostval SHARD_PRIVATE_IP)
in_private_net "$SELF" || die "SHARD_PRIVATE_IP missing from $DEST/host.env"
[ "$NEW_PRIV" != "$SELF" ] || die "the new shard's private IP is this host's"
(cd "$DEST" && docker compose ps -q haproxy 2>/dev/null) | grep -q . || die "HAProxy is not running here: run install.sh in shard mode first"
# shellcheck source=../VERSION
source "$HERE/VERSION"
[ "$(envval JITSI_IMAGE_VERSION)" = "$DJM_TAG" ] || die "this host runs $(envval JITSI_IMAGE_VERSION), VERSION says $DJM_TAG: use the matching checkout"
CFG=$(envval CONFIG); CFG=${CFG/#\~/$HOME}
for f in "$DEST/jwt/private.pem" "$CFG/web/keys/cert.crt" "$CFG/web/keys/cert.key"; do
  [ -f "$f" ] || die "$f missing"
done

# shards.list: add the new shard once.
if awk -v ip="$NEW_PRIV" '{sub(/#.*/, "")} $1 == ip {f=1} END {exit !f}' "$DEST/shards.list"; then
  echo "$NEW_PRIV is already in $DEST/shards.list"
else
  printf '%s %s\n' "$NEW_PRIV" "$NAME" >>"$DEST/shards.list"
fi

umask 077
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
S=$WORK/talkchief-meet-shard
mkdir -p "$S/seed/jwt" "$S/seed/web-keys" "$S/seed/certs"
tar -C "$HERE/.." -cf - deploy | tar -C "$S" -xf -
cp "$DEST/.env" "$S/seed/env"
cp "$DEST/jwt/private.pem" "$S/seed/jwt/private.pem"
cp "$CFG/web/keys/cert.crt" "$CFG/web/keys/cert.key" "$S/seed/web-keys/"
for f in turn.crt turn.key; do [ -f "$DEST/certs/$f" ] && cp "$DEST/certs/$f" "$S/seed/certs/"; done
cp "$DEST/shards.list" "$S/seed/shards.list"
[ -f "$DEST/bridges.allow" ] && cp "$DEST/bridges.allow" "$S/seed/bridges.allow"
cat >"$S/seed/host.env" <<EOF
# Settings for this shard host only (install.sh applies them after the
# managed block). Written by shard-bundle.sh on $(hostname) $(date -u +%FT%TZ).
SHARD_NAME=$NAME
SHARD_PRIVATE_IP=$NEW_PRIV
PROSODY_C2S_BIND=$NEW_PRIV
JVB_ADVERTISE_IPS=$NEW_PUB
MONITOR_BRIDGES=$(envval MONITOR_BRIDGES)
EOF
install -m 0755 "$HERE/scripts/shard-join.sh" "$S/shard-join.sh"

mkdir -p "$OUT_DIR"
OUT=$OUT_DIR/shard-$NAME.tgz
tar -czf "$OUT.part" -C "$WORK" talkchief-meet-shard
chmod 600 "$OUT.part"; mv -f "$OUT.part" "$OUT"

cat <<EOF
Bundle: $OUT (0600; contains every Meet secret: treat like the host itself)
Next, over the private network only:
  scp $OUT root@$NEW_PRIV:/root/
  ssh root@$NEW_PRIV 'tar -xzf /root/shard-$NAME.tgz -C /root && /root/talkchief-meet-shard/shard-join.sh'
Then copy $DEST/shards.list to EVERY other shard host and re-run install.sh on
each (HAProxy reloads; nothing restarts), re-bundle and re-join every bridge
(so it joins the new shard too), and add $NEW_PUB to the load balancer and to
turn.talkchief.io. Delete the tarball on both hosts.
EOF
