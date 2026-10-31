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

## Call diagnostics

Each person's meeting page (`web/branding/static/talkchief-room.js`) keeps a small record of its own connection. It is sent to `/talkchief-diag` every minute and on leave, and passes through the internal `events` nginx (rate-limited, accepted reports only). It is written one JSON line per report to `/opt/talkchief-meet/diag/diag-YYYY-MM-DD.jsonl`, and files older than 14 days are deleted by `/etc/cron.daily/talkchief-meet-diag`.

- **Not stored:** names, addresses, device labels.
- **Stored:**
  - the room and endpoint ID, the same `epId` the JVB and jicofo logs use;
  - the browser;
  - every 10 s: `[time, ice, audio sent, audio received, lost, concealed %, jitter ms, rtt ms, path (host/srflx/relay + udp/tcp), mic (on/off/silenced/ended/none), paused incoming audio, video received]`, the counts covering the last 10 s;
  - events: joined/left, media interrupted/restored, ICE and connection state, mic ended/silenced/back, `audio-restarted` (the audio safety net started paused incoming audio again), page hidden/shown, offline/online.

To look up a participant, find their `epId` in the JVB log, then:

```bash
grep '\\"ep\\":\\"415c42bd\\"' /opt/talkchief-meet/diag/diag-2026-10-31.jsonl
```

## Security model

* **Login:** members use JWTs only (`AUTH_TYPE=jwt`, `JWT_ALLOW_EMPTY=0`). Tokens are RS256, issuer `talkchief-cowork`, audience `talkchief-meet`. External guests join anonymously through the guest VirtualHost (`ENABLE_GUESTS=1`), only into `g-` rooms (`mod_talkchief_room_policy`).
* **Tenancy:** each room is scoped to a tenant at `/<team>/<room-uuid>`, and the token must carry `sub=<team>` and a `room` claim that matches the room.
* **Moderators:** granted only through the token's `context.user.affiliation` (`token_affiliation`). Guests wait for a host (`muc_wait_for_host`), go through the lobby, and are never auto-promoted.
* **Waiting for a host needs `mod_persistent_lobby` on the main VirtualHost.** `muc_wait_for_host` only fires `create-persistent-lobby-room`; without `persistent_lobby` nothing creates the lobby and a guest walks straight into an empty `g-` room (seen in production on 2026-10-31). The image has no main-VirtualHost-only module setting (`XMPP_MODULES` also loads modules on the guest VirtualHost), so `mod_talkchief_room_policy` loads it and logs `loaded persistent_lobby on meet.jitsi`. As a second line, the policy refuses a guest in a `g-` room that has had no member and has no lobby (`no member yet and no waiting lobby` in the log).

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
