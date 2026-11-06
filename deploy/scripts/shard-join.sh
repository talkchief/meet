#!/usr/bin/env bash
# Joins this host as a TalkChief Meet shard (RUNBOOK-shards.md). Run as root
# from the unpacked bundle that scripts/shard-bundle.sh made on an existing
# shard:
#
#   tar -xzf /root/shard-<name>.tgz -C /root && /root/talkchief-meet-shard/shard-join.sh
#
# Seeds /opt/talkchief-meet with the shared secrets BEFORE the first install
# (install.sh keeps existing secrets, so this shard uses the same JWT key,
# XMPP passwords and TURN secret as every other shard), then runs install.sh
# from the bundled deploy/ checkout and checks HAProxy and the shard's health.
# Refuses a host that already has a different Meet install.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST=/opt/talkchief-meet
die() { echo "shard-join: $*" >&2; exit 1; }
ok() { echo "  ok: $*"; }
[ "$(id -u)" = 0 ] || die "run as root"
[ -f "$SRC/seed/env" ] && [ -f "$SRC/seed/host.env" ] && [ -d "$SRC/deploy" ] || die "run from the unpacked shard bundle"
hostval() { grep -E "^$1=" "$SRC/seed/host.env" | tail -1 | cut -d= -f2- || true; }
SELF=$(hostval SHARD_PRIVATE_IP)
ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$SELF" || die "SHARD_PRIVATE_IP $SELF is not an address of this host (wrong bundle?)"
ok "private IP $SELF"
command -v docker >/dev/null && docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 || die "Docker with compose v2 is required"

if [ -f "$DEST/jwt/private.pem" ]; then
  cmp -s "$DEST/jwt/private.pem" "$SRC/seed/jwt/private.pem" ||
    die "$DEST already holds a different meeting key: this host belongs to another install; refusing to overwrite"
  ok "existing install with the same key (re-join)"
fi

umask 077
install -d -m 0755 "$DEST"
[ -f "$DEST/.env" ] || install -m 0600 "$SRC/seed/env" "$DEST/.env"
install -m 0600 "$SRC/seed/host.env" "$DEST/host.env"
install -m 0644 "$SRC/seed/shards.list" "$DEST/shards.list"
[ -f "$SRC/seed/bridges.allow" ] && install -m 0644 "$SRC/seed/bridges.allow" "$DEST/bridges.allow"
install -d -m 0700 "$DEST/jwt" && install -m 0600 "$SRC/seed/jwt/private.pem" "$DEST/jwt/private.pem"
if [ -f "$SRC/seed/certs/turn.crt" ]; then
  install -d -m 0700 "$DEST/certs"
  install -m 0644 "$SRC/seed/certs/turn.crt" "$DEST/certs/turn.crt"
  install -m 0600 "$SRC/seed/certs/turn.key" "$DEST/certs/turn.key"
fi
CFG=$(grep -E '^CONFIG=' "$DEST/.env" | tail -1 | cut -d= -f2-); CFG=${CFG/#\~/$HOME}
install -d -m 0755 "$CFG/web/keys"
install -m 0644 "$SRC/seed/web-keys/cert.crt" "$CFG/web/keys/cert.crt"
install -m 0600 "$SRC/seed/web-keys/cert.key" "$CFG/web/keys/cert.key"
ok "secrets seeded"

# The checkout this shard runs from (like /opt/talkchief-meet-src on the first).
rm -rf /opt/talkchief-meet-src.new && mkdir -p /opt/talkchief-meet-src.new
cp -a "$SRC/deploy" /opt/talkchief-meet-src.new/deploy
rm -rf /opt/talkchief-meet-src.prev
[ -d /opt/talkchief-meet-src ] && mv /opt/talkchief-meet-src /opt/talkchief-meet-src.prev
mv /opt/talkchief-meet-src.new /opt/talkchief-meet-src
(umask 022 && bash /opt/talkchief-meet-src/deploy/scripts/install.sh)

for _ in $(seq 1 60); do
  curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:8888/stats 2>/dev/null && break
  sleep 5
done
curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:8888/stats || die "jicofo does not answer after 5 min (docker compose logs jicofo)"
ok "jicofo answers"
curl -fsSk --max-time 5 -o /dev/null -H 'X-Talkchief-Shard-Check: 1' "https://$SELF:8443/talkchief-shard-health" || die "shard health (web → jicofo) does not answer on $SELF:8443"
ok "shard health on $SELF:8443"
curl -fsSk --max-time 5 -o /dev/null https://127.0.0.1/talkchief-haproxy-health || die "HAProxy does not answer on 443"
ok "HAProxy on 443"
cat <<EOF

Shard $(hostval SHARD_NAME) ($SELF) is up. Remaining (RUNBOOK-shards.md, "Add a shard"):
copy /opt/talkchief-meet/shards.list to every other shard and re-run install.sh
there, re-join every bridge, then add this host to the load balancer.
EOF
