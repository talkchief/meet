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
rm -rf "$DEST/web-tc" && cp -r "$HERE/web" "$DEST/web-tc"
sed -i 's#context: ./web#context: ./web-tc#' "$DEST/docker-compose.override.yml"
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

# 5. Config dirs, custom web config, coturn.
CFG=$(grep -E '^CONFIG=' "$DEST/.env" | tail -1 | cut -d= -f2)
prosody_cfg_sum() { cat "$CFG"/prosody/prosody-plugins-custom/*.lua 2>/dev/null | sha256sum; }
web_cfg_sum() { cat "$CFG"/web/custom-*.js "$CFG"/web/nginx/custom-meet.conf "$CFG"/web/keys/cert.crt 2>/dev/null | sha256sum; }
before=$(web_cfg_sum)
before_prosody=$(prosody_cfg_sum)
mkdir -p "$CFG"/{web/keys,web/custom-ca,storage/web,storage/prosody,storage/transcripts,tmp/web-load-test,prosody/config,prosody/prosody-plugins-custom,prosody/custom-ca,jicofo/custom-ca,jvb/custom-ca,jigasi,jibri}
cp "$HERE/web/custom-config.js" "$HERE/web/custom-interface_config.js" "$CFG/web/"
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

# 6. Build branded web image and start.
cd "$DEST"
docker compose build web
docker compose up -d --remove-orphans
# Config files live on a volume, so compose does not notice when they change.
# A web restart briefly drops signalling (clients reconnect); only do it when needed.
if [ "$before_prosody" != "$(prosody_cfg_sum)" ]; then
  # Prosody restarts drop every live conference; jicofo/jvb/web reconnect to it.
  docker compose up -d --force-recreate prosody jicofo jvb web
elif [ "$before" != "$(web_cfg_sum)" ]; then
  docker compose restart web
fi
docker compose ps
