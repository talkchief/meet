#!/usr/bin/env bash
# Installs or upgrades TalkChief Cowork Meetings (branded Jitsi) on this host.
# Idempotent: secrets in /opt/talkchief-meet/.env and the RS256 keypair are
# generated once and never overwritten. Run as root from the deploy/ checkout.
set -euo pipefail
# The containers read these files as other users (nginx 101, coturn 65534,
# Jitsi 1000): directories and public files must be world-readable whatever
# umask the caller had. Secrets get explicit modes below.
umask 022
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST=/opt/talkchief-meet
source "$HERE/VERSION"
mkdir -p "$DEST"

# 1. Pinned upstream release, verified.
tgz="$DEST/.djm-$DJM_TAG.tgz"
if [ ! -f "$tgz" ]; then
  curl -fsSL "https://github.com/jitsi/docker-jitsi-meet/archive/refs/tags/$DJM_TAG.tar.gz" -o "$tgz.part"
  mv "$tgz.part" "$tgz"
fi
echo "$DJM_TARBALL_SHA256  $tgz" | sha256sum -c - >/dev/null || {
  # GitHub's archive endpoint and the API tarball differ byte-wise; compare the compose file instead.
  tmp=$(mktemp -d); tar -xzf "$tgz" -C "$tmp"
  cmp -s "$tmp"/*/docker-compose.yml "$HERE/upstream-docker-compose.yml" || { echo "upstream compose mismatch for $DJM_TAG" >&2; exit 1; }
  rm -rf "$tmp"
}
tar -xzf "$tgz" -C "$DEST" --strip-components=1

# 2. TalkChief overlay.
cp "$HERE/docker-compose.override.yml" "$DEST/"
# Internal room-events relay config (a stray directory here, left by a start
# before this file existed, is replaced).
[ -d "$DEST/events/events.conf" ] && rmdir "$DEST/events/events.conf"
install -d -m 755 "$DEST/events" && install -m 644 "$HERE/events/events.conf" "$DEST/events/events.conf"
rm -rf "$DEST/web-tc" && cp -r "$HERE/web" "$DEST/web-tc"
sed -i 's#context: ./web#context: ./web-tc#' "$DEST/docker-compose.override.yml"
rm -rf "$DEST/monitor-tc" && cp -r "$HERE/monitor" "$DEST/monitor-tc"
sed -i 's#context: ./monitor#context: ./monitor-tc#' "$DEST/docker-compose.override.yml"
mkdir -p "$DEST/asap" "$DEST/coturn"
chmod 755 "$DEST/asap" "$DEST/coturn"

# 3. .env: upstream example + TalkChief overrides + secrets (first run only).
if [ ! -f "$DEST/.env" ]; then
  cp "$DEST/env.example" "$DEST/.env"
  (cd "$DEST" && ./gen-passwords.sh)
  cat "$HERE/env.talkchief" >> "$DEST/.env"
  echo "TURN_CREDENTIALS=$(openssl rand -hex 32)" >> "$DEST/.env"
  echo "JITSI_IMAGE_VERSION=$DJM_TAG" >> "$DEST/.env"
  chmod 600 "$DEST/.env"
else
  # Re-apply non-secret overrides on upgrade: later keys win in docker compose .env.
  sed -i '/^# >>> talkchief overrides/,/^# <<< talkchief overrides/d' "$DEST/.env"
  { echo "# >>> talkchief overrides"; cat "$HERE/env.talkchief"; echo "JITSI_IMAGE_VERSION=$DJM_TAG"; echo "# <<< talkchief overrides"; } >> "$DEST/.env"
fi

# 3b. Shards (RUNBOOK-shards.md). Default off: a host without
# /opt/talkchief-meet/shards.list runs exactly as before. With it, HAProxy
# takes ports 80/443 (shard/haproxy.cfg.template) and the web container moves
# to SHARD_PRIVATE_IP:8443. Per-host settings (this shard's addresses) live in
# /opt/talkchief-meet/host.env and are re-applied after the managed block
# above, so they win over env.talkchief.
hostval() { [ -f "$DEST/host.env" ] && grep -E "^$1=" "$DEST/host.env" | tail -1 | cut -d= -f2- || true; }
is_private_ip() { case "$1" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;; *) return 1 ;; esac; }
is_local_ip() { ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$1"; }
SHARD_MODE=0
if [ -f "$DEST/shards.list" ]; then
  SHARD_MODE=1
  SHARD_IP=$(hostval SHARD_PRIVATE_IP)
  is_private_ip "$SHARD_IP" && is_local_ip "$SHARD_IP" || {
    echo "shard mode ($DEST/shards.list exists): SHARD_PRIVATE_IP in $DEST/host.env must be this host's private IP" >&2; exit 1; }
  grep -Eq "^[[:space:]]*${SHARD_IP//./\.}([[:space:]]|$)" "$DEST/shards.list" || {
    echo "shard mode: this host ($SHARD_IP) is not listed in $DEST/shards.list" >&2; exit 1; }
fi
sed -i '/^# >>> host overrides/,/^# <<< host overrides/d' "$DEST/.env"
if [ -f "$DEST/host.env" ] || [ "$SHARD_MODE" = 1 ]; then
  {
    echo "# >>> host overrides"
    [ -f "$DEST/host.env" ] && grep -E '^[A-Z_][A-Z0-9_]*=' "$DEST/host.env" || true
    if [ "$SHARD_MODE" = 1 ]; then
      echo "COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:docker-compose.shard.yml"
      # Plain HTTP stays on loopback: only the TLS port is for the shard hosts.
      echo "HTTP_PORT=127.0.0.1:8000"
      echo "HTTPS_PORT=$SHARD_IP:8443"
      echo "ENABLE_HTTP_REDIRECT=0"
    fi
    echo "# <<< host overrides"
  } >> "$DEST/.env"
fi

# 4. RS256 keypair for JWTs (private key is handed to the Cowork meetings plugin, never served).
KID=talkchief-cowork-1
if [ ! -f "$DEST/jwt/private.pem" ]; then
  install -d -m 700 "$DEST/jwt"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$DEST/jwt/private.pem"
  chmod 600 "$DEST/jwt/private.pem"
fi
openssl pkey -in "$DEST/jwt/private.pem" -pubout -out "$DEST/asap/$(printf %s "$KID" | sha256sum | cut -d' ' -f1).pem"
chmod 644 "$DEST"/asap/*.pem
# Room-events HMAC key (mod_talkchief_room_events): derived from the signing
# key, which Cowork also holds, so nothing extra is copied between servers.
# Cowork computes the same value (EventsSecretFromKey).
EVS=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(b"talkchief-meet-events-v1:" + open(sys.argv[1], "rb").read().strip()).hexdigest())' "$DEST/jwt/private.pem")
sed -i '/^TALKCHIEF_EVENTS_SECRET=/d' "$DEST/.env"
echo "TALKCHIEF_EVENTS_SECRET=$EVS" >> "$DEST/.env"

# 5. Config dirs, custom web config, coturn.
CFG=$(grep -E '^CONFIG=' "$DEST/.env" | tail -1 | cut -d= -f2)
prosody_cfg_sum() { { cat "$CFG"/prosody/prosody-plugins-custom/*.lua 2>/dev/null || true; } | sha256sum; }
web_cfg_sum() { { cat "$CFG"/web/custom-*.js "$CFG"/web/nginx/custom-meet.conf "$CFG"/web/keys/cert.crt 2>/dev/null || true; } | sha256sum; }
before=$(web_cfg_sum)
before_prosody=$(prosody_cfg_sum)
mkdir -p "$CFG"/{web/keys,web/custom-ca,storage/web,storage/prosody,storage/transcripts,tmp/web-load-test,prosody/config,prosody/prosody-plugins-custom,prosody/custom-ca,jicofo/custom-ca,jvb/custom-ca,jigasi,jibri}
cp "$HERE/web/custom-config.js" "$HERE/web/custom-interface_config.js" "$CFG/web/"
# Versioned branding URL, so browsers pick up palette changes at once.
BRAND_V=$(sha256sum "$HERE/web/branding/static/talkchief-branding.json" | cut -c1-12)
sed -i "s#static/talkchief-branding.json'#static/talkchief-branding.json?v=${BRAND_V}'#" "$CFG/web/custom-config.js"
mkdir -p "$CFG/web/nginx" && cp "$HERE/web/custom-meet.conf" "$CFG/web/nginx/custom-meet.conf"
cp "$HERE"/prosody/plugins/*.lua "$CFG/prosody/prosody-plugins-custom/"
# The Jitsi images run as uid/gid 1000 (s6); every host volume, including the
# TLS key in web/keys, must belong to that user.
chown -R 1000:1000 "$CFG"
[ -f "$CFG/web/keys/cert.key" ] && chmod 600 "$CFG/web/keys/cert.key"
TS=$(grep -E '^TURN_CREDENTIALS=' "$DEST/.env" | tail -1 | cut -d= -f2)
# The template carries the main host's public IP; another shard relays on its
# own (JVB_ADVERTISE_IPS from host.env, the last value in .env).
TURN_IP=$(grep -E '^JVB_ADVERTISE_IPS=' "$DEST/.env" | tail -1 | cut -d= -f2 | cut -d, -f1)
[[ $TURN_IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || TURN_IP=46.225.31.248
sed -e "s/__TURN_SECRET__/$TS/" -e "s/46\.225\.31\.248/$TURN_IP/g" "$HERE/coturn/turnserver.conf.template" > "$DEST/coturn/turnserver.conf"
chmod 644 "$DEST/coturn/turnserver.conf"
# coturn runs as nobody (65534): give it a private copy of the TalkChief wildcard cert.
if [ -f "$DEST/certs/turn.crt" ] && [ -f "$DEST/certs/turn.key" ]; then
  install -d -m 0750 -o 65534 -g 65534 "$DEST/coturn/certs"
  install -m 0444 -o 65534 -g 65534 "$DEST/certs/turn.crt" "$DEST/coturn/certs/turn.crt"
  install -m 0400 -o 65534 -g 65534 "$DEST/certs/turn.key" "$DEST/coturn/certs/turn.key"
else
  echo "WARN: $DEST/certs/turn.{crt,key} missing; TURNS (5349) will not start" >&2
fi

# Shard entry config (shard mode). Rendered and checked with the pinned
# HAProxy image before it replaces the live file; HAProxy reloads it below
# without dropping connections.
haproxy_sum() { { cat "$DEST/haproxy/haproxy.cfg" "$DEST/haproxy/meet.pem" 2>/dev/null || true; } | sha256sum; }
before_haproxy=$(haproxy_sum)
if [ "$SHARD_MODE" = 1 ]; then
  cp "$HERE/shard/docker-compose.shard.yml" "$DEST/"
  [ -f "$CFG/web/keys/cert.crt" ] && [ -f "$CFG/web/keys/cert.key" ] || {
    echo "shard mode: $CFG/web/keys/cert.{crt,key} missing (HAProxy terminates TLS with the web certificate)" >&2; exit 1; }
  install -d -m 0700 "$DEST/haproxy"
  tmp=$(mktemp -d "$DEST/haproxy/.new.XXXXXX")
  cat "$CFG/web/keys/cert.crt" "$CFG/web/keys/cert.key" > "$tmp/meet.pem"
  python3 - "$HERE/shard/haproxy.cfg.template" "$DEST/shards.list" "$tmp/haproxy.cfg" "$SHARD_IP" <<'PY'
import ipaddress, re, sys
tpl, lst, out, self_ip = sys.argv[1:]
servers, peers, local = [], [], None
for raw in open(lst):
    line = raw.split("#", 1)[0].split()
    if not line:
        continue
    ip, name = line[0], (line[1] if len(line) > 1 else "shard-" + line[0].replace(".", "-"))
    if not ipaddress.ip_address(ip).is_private or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,30}", name):
        sys.exit(f"shards.list: bad entry {raw.strip()!r}")
    # A stable id from the address (unique in 10.0.0.0/8): the consistent-hash
    # ring is built from server ids, so every shard host gets the same ring.
    a = ipaddress.ip_address(ip).packed
    servers.append(f"    server {name} {ip}:8443 id {a[1] * 65536 + a[2] * 256 + a[3] + 1}")
    # Stick-table sync between the shard HAProxies (room -> shard survives a
    # shard's recovery); the local peer is this host's own line.
    peers.append(f"    peer {name} {ip}:8445")
    if ip == self_ip:
        local = name
if not servers:
    sys.exit("shards.list lists no shard")
if local is None:
    sys.exit("shards.list does not list this host")
if len({p.split()[1] for p in peers}) != len(peers):
    sys.exit("shards.list: shard names must be unique")
cfg = open(tpl).read().replace("@SERVERS@", chr(10).join(servers))
open(out, "w").write(cfg.replace("@PEERS@", chr(10).join(peers)).replace("@LOCALPEER@", local))
PY
  HAPROXY_IMAGE=$(python3 -c 'import re,sys; print(re.search(r"image:\s*(\S+)", open(sys.argv[1]).read()).group(1))' "$HERE/shard/docker-compose.shard.yml")
  docker run --rm --user 0:0 -v "$tmp:/usr/local/etc/haproxy:ro" "$HAPROXY_IMAGE" haproxy -c -q -f /usr/local/etc/haproxy/haproxy.cfg || {
    echo "shard mode: rendered HAProxy config does not validate (kept in $tmp)" >&2; exit 1; }
  chmod 600 "$tmp/meet.pem" "$tmp/haproxy.cfg"
  mv -f "$tmp/meet.pem" "$DEST/haproxy/meet.pem"; mv -f "$tmp/haproxy.cfg" "$DEST/haproxy/haproxy.cfg"; rmdir "$tmp"
else
  rm -f "$DEST/docker-compose.shard.yml"
fi

# Call diagnostics (events nginx writes them; nginx runs as uid 101): kept 14 days.
install -d -m 0750 -o 101 -g 101 "$DEST/diag"
cat > /etc/cron.daily/talkchief-meet-diag <<EOF
#!/bin/sh
find "$DEST/diag" -name 'diag-*.jsonl' -mtime +14 -delete
EOF
chmod 755 /etc/cron.daily/talkchief-meet-diag

# 5b. Private-network allowlist for Prosody's client port (scripts/meet-fw.sh,
# RUNBOOK-bridge-node.md). The script and unit are always installed (inert
# files). The unit is enabled only once it has something to protect: an
# allowlist exists, or PROSODY_C2S_BIND publishes 5222 on a private IP. In the
# second case it must be applied before compose publishes the port, so a
# failure here stops the install.
envval() { grep -E "^$1=" "$DEST/.env" | tail -1 | cut -d= -f2- || true; }
# .env is the only source: a value exported in this shell would win over .env
# in docker compose and bypass the checks below.
unset PROSODY_C2S_BIND
C2S_BIND=$(envval PROSODY_C2S_BIND); C2S_BIND=${C2S_BIND:-127.0.0.1}
case "$C2S_BIND" in
  127.*) ;;
  10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
    ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$C2S_BIND" || {
      echo "PROSODY_C2S_BIND=$C2S_BIND is not an address of this host" >&2; exit 1; }
    ;;
  *) echo "PROSODY_C2S_BIND=$C2S_BIND: must be 127.0.0.1 or this host's private IP, never public" >&2; exit 1 ;;
esac
install -m 0755 "$HERE/scripts/meet-fw.sh" /usr/local/sbin/talkchief-meet-fw
install -m 0644 "$HERE/scripts/talkchief-meet-fw.service" /etc/systemd/system/talkchief-meet-fw.service
systemctl daemon-reload
# `enable` also makes docker.service Require the unit (drop-in), so Docker
# never starts without the allowlist; a running Docker is not restarted.
if [ -f "$DEST/bridges.allow" ] || [ "${C2S_BIND#127.}" = "$C2S_BIND" ]; then
  /usr/local/sbin/talkchief-meet-fw --role main enable
fi
install -m 0644 "$HERE/scripts/talkchief-meet-shard-fw.service" /etc/systemd/system/talkchief-meet-shard-fw.service
systemctl daemon-reload
# Shard mode: the web container's 8443 is published on the private IP only
# for the other shard hosts' HAProxy; the allowlist is applied before compose
# publishes it.
if [ "$SHARD_MODE" = 1 ]; then
  /usr/local/sbin/talkchief-meet-fw --role shard enable
elif systemctl is-enabled --quiet talkchief-meet-shard-fw.service 2>/dev/null; then
  # Leaving shard mode (rollback): Docker must no longer require the shard
  # allowlist, whose settings are gone.
  /usr/local/sbin/talkchief-meet-fw --role shard disable
  /usr/local/sbin/talkchief-meet-fw --role shard remove
fi

# Restarting prosody, jicofo or jvb drops every live meeting, and
# `docker compose up` recreates any service whose image or settings changed.
# Rule: such a step runs only while jicofo reports zero conferences. There is
# no override. wait_for_idle runs immediately before EACH such step (images
# are pulled and built first, so nothing slow sits between the check and the
# step), waits up to IDLE_WAIT_MIN minutes (default 60) and otherwise exits 2.
# Fail closed: if the stats cannot be read, it waits and refuses, except when
# the stack is verifiably absent (no container of this compose project in any
# state, i.e. a first install or after `docker compose down`).
jicofo_conferences() {
  curl -fsS --max-time 5 http://127.0.0.1:8888/stats 2>/dev/null |
    python3 -c 'import json,sys; c=json.load(sys.stdin).get("conferences"); print(c if isinstance(c,int) and not isinstance(c,bool) and c>=0 else "")' 2>/dev/null || true
}
# Prints "absent", "present" or nothing (cannot tell).
stack_state() {
  local project ids
  project=$(docker compose config --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])' 2>/dev/null) || return 0
  [ -n "$project" ] || return 0
  ids=$(docker ps -aq --filter "label=com.docker.compose.project=$project" 2>/dev/null) || return 0
  if [ -z "$ids" ]; then echo absent; else echo present; fi
}
wait_for_idle() {
  local step=$1 wait_min=${IDLE_WAIT_MIN:-60} deadline c state
  case "$wait_min" in ''|*[!0-9]*) echo "IDLE_WAIT_MIN must be a whole number of minutes" >&2; exit 2 ;; esac
  deadline=$(( $(date +%s) + wait_min * 60 ))
  while :; do
    c=$(jicofo_conferences)
    if [ "$c" = 0 ]; then
      echo "jicofo reports 0 conferences: $step"; return 0
    elif [ -n "$c" ]; then
      echo "waiting before '$step': jicofo reports $c live conference(s)"
    else
      state=$(stack_state)
      if [ "$state" = absent ]; then
        echo "no container of this stack exists (first install): $step"; return 0
      elif [ "$state" = present ]; then
        echo "waiting before '$step': the stack exists but jicofo stats (127.0.0.1:8888/stats) cannot be read (starting, paused, restarting or down)" >&2
      else
        echo "waiting before '$step': jicofo stats cannot be read and docker cannot say whether the stack exists" >&2
      fi
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 10
  done
  echo "refusing to $step: jicofo did not report zero conferences within ${wait_min} min" >&2
  exit 2
}
# Images for every service that is not built here, pulled up front.
pull_images() {
  local svcs
  svcs=$(docker compose config --format json | python3 -c 'import json,sys; print(" ".join(n for n, s in json.load(sys.stdin)["services"].items() if "build" not in s))')
  # shellcheck disable=SC2086
  [ -z "$svcs" ] || docker compose pull $svcs
}

# 6. Build and pull everything first, then start. Nothing below builds or pulls.
cd "$DEST"
docker compose build web monitor
pull_images
prosody_id() { docker compose ps -q prosody 2>/dev/null || true; }
before_prosody_id=$(prosody_id)
wait_for_idle "start/update the stack"
docker compose up -d --no-build --remove-orphans
# Config files live on a volume, so compose does not notice when they change.
# A web restart briefly drops signalling (clients reconnect); only do it when needed.
if [ "$before_prosody" != "$(prosody_cfg_sum)" ]; then
  # Prosody restarts drop every live conference; jicofo/jvb/web reconnect to it.
  wait_for_idle "recreate prosody, jicofo, jvb and web"
  docker compose up -d --no-build --force-recreate prosody jicofo jvb web
else
  if [ -n "$before_prosody_id" ] && [ "$before_prosody_id" != "$(prosody_id)" ]; then
    # `up` recreated prosody (its image, env or ports changed) but kept jicofo
    # and jvb running. Their reconnect to the new prosody is rate-limited and
    # jicofo's bridge health checks then time out: 0 operational bridges, no
    # meetings (seen on 2026-11-06). Restart both so they join cleanly.
    wait_for_idle "restart jvb and jicofo after prosody was recreated"
    docker compose restart jvb jicofo
  fi
  if [ "$before" != "$(web_cfg_sum)" ]; then
    wait_for_idle "restart web"
    docker compose restart web
  fi
fi
# HAProxy reads its config once: reload it in place (live connections stay).
if [ "$SHARD_MODE" = 1 ] && [ "$before_haproxy" != "$(haproxy_sum)" ] && [ -n "$(docker compose ps -q haproxy 2>/dev/null)" ]; then
  docker compose kill -s USR2 haproxy
fi
# events.conf is a mounted file: reload it (harmless when unchanged).
docker compose exec -T events nginx -s reload || true
docker compose ps
