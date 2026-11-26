#!/usr/bin/env bash
# VM test setup: the meeting service's Prosody and Jicofo (docker-jitsi-meet,
# deploy/VERSION) with the TalkChief Prosody modules and deploy/env.talkchief,
# a fake Cowork instead of the events relay, and an ASAP key for test tokens.
set -euo pipefail
cd /home/user/meet/deploy
TAG=$(grep '^DJM_TAG=' VERSION | cut -d= -f2)
CFG=/home/user/meetcfg
mkdir -p $CFG/{web/keys,storage/web,storage/prosody,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb} /home/user/state /home/user/meet/deploy/asap
cp prosody/plugins/*.lua $CFG/prosody/prosody-plugins-custom/
echo '{}' > /home/user/state/rooms.json; : > /home/user/state/events.log

# .env like install.sh: upstream example, generated passwords, our overrides.
cp upstream-env.example .env
bash upstream-gen-passwords.sh >/dev/null
cat env.talkchief >> .env
sed -i "s#^CONFIG=.*#CONFIG=$CFG#" .env
# A short host-drop grace so the test runs quickly (production: 60).
sed -i 's#talkchief_host_drop_grace=60#talkchief_host_drop_grace=10#' .env
cat >> .env <<EOF
JITSI_IMAGE_VERSION=$TAG
TALKCHIEF_EVENTS_SECRET=testsecret
PUBLIC_URL=https://meet.test
EOF

# Test signing key: public half served by asap like production.
openssl genrsa -out /home/user/state/key.pem 2048 2>/dev/null
openssl rsa -in /home/user/state/key.pem -pubout -out asap/$(printf '%s' talkchief-cowork-1 | sha256sum | cut -d' ' -f1).pem 2>/dev/null

# The fake Cowork takes the events relay's place on the compose network.
cat > docker-compose.vmtest.yml <<'EOF'
services:
  events:
    image: python:3.12-alpine
    command: ["python", "/it/fake_cowork.py"]
    environment:
      - SECRET=testsecret
    volumes:
      - /home/user/meet/deploy/prosody/tests/vm:/it:ro
      - /home/user/state:/state
EOF
docker compose -f upstream-docker-compose.yml -f docker-compose.override.yml -f docker-compose.vmtest.yml up -d prosody jicofo asap events
sleep 30
docker compose -f upstream-docker-compose.yml -f docker-compose.override.yml -f docker-compose.vmtest.yml ps
docker compose -f upstream-docker-compose.yml -f docker-compose.override.yml -f docker-compose.vmtest.yml logs prosody 2>&1 | grep -i -E "talkchief|error" | tail -20
