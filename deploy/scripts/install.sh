#!/usr/bin/env bash
# Installs or upgrades TalkChief Cowork Meetings (branded Jitsi) on this host.
# Idempotent: secrets in /opt/talkchief-meet/.env and the RS256 keypair are
# generated once and never overwritten. Run as root from the deploy/ checkout.
set -euo pipefail
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
sed "s/__TURN_SECRET__/$TS/" "$HERE/coturn/turnserver.conf.template" > "$DEST/coturn/turnserver.conf"
chmod 644 "$DEST/coturn/turnserver.conf"
# coturn runs as nobody (65534): give it a private copy of the TalkChief wildcard cert.
if [ -f "$DEST/certs/turn.crt" ] && [ -f "$DEST/certs/turn.key" ]; then
  install -d -m 0750 -o 65534 -g 65534 "$DEST/coturn/certs"
  install -m 0444 -o 65534 -g 65534 "$DEST/certs/turn.crt" "$DEST/coturn/certs/turn.crt"
  install -m 0400 -o 65534 -g 65534 "$DEST/certs/turn.key" "$DEST/coturn/certs/turn.key"
else
  echo "WARN: $DEST/certs/turn.{crt,key} missing; TURNS (5349) will not start" >&2
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
wait_for_idle "start/update the stack"
docker compose up -d --no-build --remove-orphans
# Config files live on a volume, so compose does not notice when they change.
# A web restart briefly drops signalling (clients reconnect); only do it when needed.
if [ "$before_prosody" != "$(prosody_cfg_sum)" ]; then
  # Prosody restarts drop every live conference; jicofo/jvb/web reconnect to it.
  wait_for_idle "recreate prosody, jicofo, jvb and web"
  docker compose up -d --no-build --force-recreate prosody jicofo jvb web
elif [ "$before" != "$(web_cfg_sum)" ]; then
  wait_for_idle "restart web"
  docker compose restart web
fi
# events.conf is a mounted file: reload it (harmless when unchanged).
docker compose exec -T events nginx -s reload || true
docker compose ps
