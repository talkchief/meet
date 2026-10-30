# TalkChief Cowork Meetings: deployment

The full handover (Cowork core integration, security model, operations, follow-ups and gotchas) is in `talkchief/talkchief_cowork` at `docs/talkchief-meetings.md`.

The deployment of `meet.talkchief.io`: a self-hosted, fully rebranded Jitsi stack that serves TalkChief Cowork group calls and meetings.

* Upstream: docker-jitsi-meet, pinned in `VERSION`.
* The upstream jitsi-meet source in this fork is **not** built. Branding is applied at image build (`web/Dockerfile` and `web/brand.sh`) and through the config overrides in `web/custom-*.js` and `web/custom-meet.conf`.

## Layout on the server (`/opt/talkchief-meet`)

| Path | What |
|---|---|
| `.env` | upstream example, generated XMPP secrets, these overrides and `TURN_CREDENTIALS` (0600) |
| `jwt/private.pem` | RS256 signing key (0600). Its only consumer is Cowork (core server, `PluginSettings.Plugins["com.talkchief.meetings"].jwtprivatekey`). |
| `asap/<sha256(kid)>.pem` | public key, served on the **internal** network only (`http://asap/asap`) |
| `config/web/keys/cert.{crt,key}` | TalkChief wildcard certificate for `meet.talkchief.io` |
| `certs/turn.{crt,key}` | the same wildcard certificate, used by coturn for TURNS on 5349 |

## Install / upgrade

```bash
git clone -b talkchief --depth 1 https://github.com/talkchief/meet.git /opt/talkchief-meet-src
/opt/talkchief-meet-src/deploy/scripts/install.sh
```

The installer is idempotent: on later runs it keeps the existing secrets and keys.

## Security model

* **Login:** JWT only (`AUTH_TYPE=jwt`, `JWT_ALLOW_EMPTY=0`, `ENABLE_GUESTS=0`). Tokens are RS256, issuer `talkchief-cowork`, audience `talkchief-meet`.
* **Tenancy:** each room is scoped to a tenant at `/<team>/<room-uuid>`, and the token must carry `sub=<team>` and a `room` claim that matches the room.
* **Moderators:** granted only through the token's `context.user.affiliation` (`token_affiliation`). Guests wait for a host (`muc_wait_for_host`), go through the lobby, and are never auto-promoted.

## Network

| Port | Purpose |
|---|---|
| 80, 443 tcp | web, proxied through Cloudflare |
| 10000 udp | media |
| 3478 udp/tcp | TURN |
| 5349 tcp | TURNS |
| 49160-49200 udp | TURN relay |

* `turn.talkchief.io` must be **DNS-only** in Cloudflare.
* SSH is reachable only on the private network.
