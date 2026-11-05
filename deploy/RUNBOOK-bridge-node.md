# Runbook: add a video bridge (JVB) node

How to give `meet.talkchief.io` another video bridge on its own Hetzner server, and how to remove it again. Background and the design rationale are in the HA audit (2026-11-06) and in the Cowork handover (`talkchief/talkchief_cowork`, `docs/talkchief-meetings.md` §12).

**Nothing in this runbook happens by itself.** Merging the repo changes does not add a bridge, publish Prosody off-host or change the firewall. Every step below is a deliberate operator action.

## What a bridge node gives you, and what it does not

* **More media capacity and media redundancy.** Jicofo sends each new conference to the least-stressed operational bridge. If a bridge dies, Jicofo moves its participants to another one after a short media gap.
* **One meeting stays on one bridge** while Octo (bridge relay) is off, which is today's setting. A second bridge adds room for *more* meetings, not *bigger* ones. See [Octo](#octo-optional) to let big meetings span bridges.
* **Signalling is still single.** Prosody, Jicofo and web stay on the main host. Losing the main host still ends every meeting. Only a [second shard](#when-to-add-a-second-shard-and-why-it-is-blocked-today) removes that.

Add a node when either:

* bridge stress stays above about 0.6 at peak (main: `curl -s 127.0.0.1:8888/stats`, `bridge_selector`; JVB: `curl -s 127.0.0.1:8080/colibri/stats`, `stress_level`); or
* you want one bridge failure not to end every meeting.

## How it fits together

```
 clients ──UDP 10000──▶ bridge node jvb  (public IP, Hetzner Cloud Firewall: UDP 10000 only)
                           │  outbound TCP 5222, private network
                           ▼
 main host 10.1.0.44 ── Prosody 5222 published on 10.1.0.44 only,
                        DOCKER-USER allowlist /opt/talkchief-meet/bridges.allow
 main monitor ──TCP 8080, private network──▶ bridge node /about/health
                        (DOCKER-USER on the node: only 10.1.0.44)
```

The bridge needs exactly one connection to the main host: outbound TCP to Prosody 5222 over the private network. Jicofo talks to it through Prosody's `jvbbrewery` room. No web proxying is needed: at the pinned release the bridge channel runs over SCTP on the media path, not colibri websockets. Re-check this on every `DJM_TAG` bump.

**Hetzner Cloud Firewalls do not filter the private network, and Docker-published ports bypass ufw.** That is why both private ports are guarded by `DOCKER-USER` rules (`scripts/meet-fw.sh`). Without them every server on 10.1.0.0/16 could reach Prosody or the bridge's status port.

**Trust:** the bridge logs in as Prosody's `jvb` account, which upstream makes a Prosody admin. Treat a bridge node as being as trusted as the main host. It receives one secret, `JVB_AUTH_PASSWORD`, and nothing else.

## Files

| File | Runs on | What |
|---|---|---|
| `docker-compose.override.yml` | main | Prosody `ports: "${PROSODY_C2S_BIND:-127.0.0.1}:5222:5222"`. The default publishes on loopback only. |
| `scripts/install.sh` | main | Waits for zero conferences before restarting anything. Installs `talkchief-meet-fw`, and enables it once `bridges.allow` exists or `PROSODY_C2S_BIND` is private. |
| `scripts/meet-fw.sh`, `scripts/talkchief-meet-fw.service` | main (and nodes) | DOCKER-USER allowlist, re-applied before Docker starts. |
| `scripts/bridge-bundle.sh` | main | Renders a node's settings and writes `/root/bridge-<name>.tgz`. Adds the node to `bridges.allow`. |
| `bridge/docker-compose.yml`, `bridge/env.bridge.template`, `bridge/custom-jvb.conf` | node | jvb only, plus the optional node monitor. |
| `bridge/join.sh`, `bridge/talkchief-meet-bridge-fw.service` | node | Preflight, firewall, start, health wait. |
| `monitor/monitor.py` | both | `BRIDGES` on main, `MONITOR_ROLE=bridge` on a node. |

## 0. Before the first node: merging this change

Merging the repo change is harmless on its own. The **next** `install.sh` run recreates Prosody, because Prosody gains a `127.0.0.1:5222` port. It also rebuilds the monitor (image `:6`). Recreating Prosody drops every live meeting.

`install.sh` now refuses to restart the stack while Jicofo reports any conference. It waits up to `IDLE_WAIT_MIN` minutes (default 60) and then exits with code 2. `FORCE=1` overrides the wait. Use it only when you accept dropping meetings.

## 1. One-time preparation of the main host (zero-conference window)

Do this once, in **one** window with no meetings, so everyone is disconnected only once.

1. **Publish Prosody on the private IP.** Set `PROSODY_C2S_BIND=10.1.0.44`. Use one of two ways:
   * **Preferred:** a reviewed PR that adds the line to `deploy/env.talkchief`. `install.sh` writes that file into the managed block of `.env`.
   * **Host-local:** append the line to `/opt/talkchief-meet/.env` *above* the `# >>> talkchief overrides` block. `install.sh` rewrites only that block.

   `install.sh` refuses any value that is not loopback or one of this host's private addresses. A public IP or `0.0.0.0` is never published.
2. **Optional, in the same window.** Each item below is otherwise a separate restart later.
   * `JICOFO_ENABLE_HEALTH_CHECKS=1`: Jicofo's `/about/health` returns 200 instead of 404. The monitor keeps checking `/stats` either way.
   * `SHUTDOWN_REST_ENABLED=true`: lets you drain the **main** host's own jvb gracefully (`POST 127.0.0.1:8080/colibri/shutdown`), for example once nodes carry all media.
   * Octo, see [Octo](#octo-optional). It has no effect while there is only one bridge.
3. **Apply** (as root, from the checkout):
   ```bash
   cd /opt/talkchief-meet-src && git pull --ff-only
   /opt/talkchief-meet-src/deploy/scripts/install.sh   # waits for 0 conferences
   ```
   With a private `PROSODY_C2S_BIND`, `install.sh` enables and applies `talkchief-meet-fw` **before** `docker compose up` publishes the port. An empty or missing allowlist means nobody may connect. If the firewall cannot be applied, the install stops before publishing.
4. **Verify:**
   ```bash
   cd /opt/talkchief-meet && docker compose port prosody 5222   # 10.1.0.44:5222
   systemctl is-active talkchief-meet-fw                          # active
   talkchief-meet-fw status                                       # jump rule + TC-MEET-XMPP ending in DROP
   iptables -S DOCKER-USER | head -3                              # our rule first
   ```
   Negative tests, which must all **fail**:
   ```bash
   nc -vz -w3 46.225.31.248 5222   # from outside: not published publicly
   nc -vz -w3 10.1.0.44 5222       # from Cowork (10.1.0.46): not in bridges.allow
   ```
   Meetings work as before: the main jvb and jicofo reach Prosody on the compose network, which the rule does not touch.

If Docker is ever switched to its nftables firewall backend, `DOCKER-USER` no longer exists and these rules do nothing. After every Docker upgrade, check that `iptables -S DOCKER-USER` still lists the rule.

## 2. Create the node (Hetzner)

* **Server:** 4 to 8 dedicated vCPU (CCX line), 1 Gbit, Ubuntu 24.04, location `fsn1` (same as main).
* **Private network:** attach it to the network that holds 10.1.0.44 and note its private IP (for example 10.1.0.50).
* **Cloud Firewall "meet-bridge":** inbound **UDP 10000 from any IPv4 and IPv6, nothing else**. No TCP, and never 22. Outbound: allow all (the jvb pulls images and reaches Prosody privately).
* **SSH only over the private network** (Hermes or the VPN). This is a hard rule: never open 22 to the internet, not even for one IP. `join.sh` refuses to run while sshd listens on `0.0.0.0`, `[::]` or a public address. A starting point for cloud-init:
  ```yaml
  #cloud-config
  package_update: true
  packages: [docker.io, docker-compose-v2]
  write_files:
    - path: /etc/ssh/sshd_config.d/10-private-only.conf
      content: |
        ListenAddress 10.1.0.50
    # Ubuntu 24.04 runs sshd from ssh.socket; let it bind the private IP
    # even before the private interface is up.
    - path: /etc/systemd/system/ssh.socket.d/10-freebind.conf
      content: |
        [Socket]
        FreeBind=yes
  runcmd:
    - [systemctl, daemon-reload]
    - [systemctl, restart, ssh.socket]
  ```
  **Not yet tested on a real node.** Test it on the first node, keep the Hetzner web console as the fallback, and confirm with `ss -ltnp | grep ':22 '` that only `10.1.0.50:22` is listed.

## 3. Bundle on the main host

The checkout must be the version the main host runs. `bridge-bundle.sh` checks this and refuses if `JITSI_IMAGE_VERSION` in `.env` differs from `VERSION`.

```bash
/opt/talkchief-meet-src/deploy/scripts/bridge-bundle.sh 10.1.0.50 <node-public-ip> bridge-1
```

The script does three things:

* It validates the IPs: private in 10.1.0.0/16, public routable, and neither is the main host's own. It also checks the name.
* It writes `/root/bridge-bridge-1.tgz` (0600). The tarball contains `JVB_AUTH_PASSWORD` and no other secret.
* It appends `10.1.0.50` to `/opt/talkchief-meet/bridges.allow` and re-applies the allowlist. This is instant; Prosody is not restarted.

Re-running it is safe.

## 4. Copy over the private network

The tarball never travels over a public address. The operator copies it through the private network:

```bash
scp root@10.1.0.44:/root/bridge-bridge-1.tgz /tmp/ && scp /tmp/bridge-bridge-1.tgz root@10.1.0.50:/root/ && rm /tmp/bridge-bridge-1.tgz
```

## 5. Join on the node

```bash
ssh root@10.1.0.50 'tar -xzf /root/bridge-bridge-1.tgz -C /root && /root/talkchief-meet-bridge/join.sh'
```

`join.sh` runs in three stages:

1. **Preflight.** It checks:
   * Docker and compose v2 are installed;
   * the node owns `10.1.0.50`;
   * the public IP matches (Hetzner metadata or a local address; `SKIP_PUBLIC_IP_CHECK=1` skips only this check);
   * **sshd is not public**;
   * Prosody answers on `10.1.0.44:5222`.
2. **Install.** It installs into `/opt/talkchief-meet-bridge`. A local `config/jvb/custom-jvb.conf` is kept on re-join. It then enables `talkchief-meet-bridge-fw`, so that only 10.1.0.44 can reach 8080 on the private IP, before anything is published.
3. **Start.** It runs `docker compose pull jvb && docker compose up -d`, then waits up to 90 s for `127.0.0.1:8080/about/health`.

Afterwards, delete `/root/bridge-bridge-1.tgz` and `/root/talkchief-meet-bridge` on the node, and the tarball on the main host.

**Node monitor:** with a Sentry DSN, the bundle sets `COMPOSE_PROFILES=monitor`. The node then builds `monitor/` locally (never pulled from a registry) and runs it with `MONITOR_ROLE=bridge`. That follows only the jvb log and checks only the local jvb. It sends no cron check-in: the main host checks the node.

**Main monitor:** in `/opt/talkchief-meet/.env` set `MONITOR_BRIDGES=10.1.0.50` (comma list for more nodes), then:

```bash
cd /opt/talkchief-meet && docker compose up -d monitor   # recreates only the monitor; meetings are untouched
```

Each node gets a `meet-jvb-<ip>` check. A warning issue opens when Jicofo sees fewer operational bridges than expected for two minutes in a row. The expected number is 1 + the nodes listed; override it with `MONITOR_EXPECTED_BRIDGES` once main's own jvb is drained. Zero bridges stays an error (`meet-bridge`).

## 6. Verify

On the **node**:

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' 127.0.0.1:8080/about/health        # 200
curl -s 127.0.0.1:8080/colibri/stats | python3 -m json.tool | grep -E '"(conferences|participants|stress_level|graceful_shutdown|drain)"'
docker compose -f /opt/talkchief-meet-bridge/docker-compose.yml logs jvb | grep -iE 'muc|xmpp' | tail
talkchief-meet-fw --role bridge status
```

On the **main host**:

```bash
curl -s 127.0.0.1:8888/stats | python3 -c 'import json,sys; print(json.load(sys.stdin)["bridge_selector"])'
#   bridge_count and operational_bridge_count: 2
cd /opt/talkchief-meet && docker compose logs jicofo --since 10m | grep -i bridge   # jvbbrewery@internal-muc.../jvb-bridge-1 added
curl -fsS -o /dev/null -w '%{http_code}\n' http://10.1.0.50:8080/about/health     # 200 (the monitor's remote check)
```

Negative tests, which must all **fail**:

```bash
nc -vz -w3 10.1.0.50 8080        # from Cowork 10.1.0.46: only 10.1.0.44 may reach it
nc -vz -w3 <node-public-ip> 22   # from outside
nc -vz -w3 <node-public-ip> 8080 # from outside
nc -vz -w3 10.1.0.44 5222        # from Cowork 10.1.0.46: still not allowlisted
```

Functional test, outside working hours:

1. Open meeting A with video, then meeting B. One of them should land on the node: `conferences` goes up in the node's `/colibri/stats`.
2. Force TURN in one client. The call diagnostics `path` shows `relay` and media flows (coturn relays to the node's public IP).

## 7. Failover drill (outside working hours)

1. Hold a test meeting that runs on the node.
2. On the node: `docker compose -f /opt/talkchief-meet-bridge/docker-compose.yml stop jvb`.
3. Expect a short media gap, after which the meeting continues on the main bridge. Jicofo `/stats` `bridge_failures.participants_moved` goes up, and the monitor reports it plus `only 1 of 2 video bridges operational`.
4. `docker compose -f /opt/talkchief-meet-bridge/docker-compose.yml start jvb`. The bridge rejoins and the warning clears.

## 8. Upgrades (`DJM_TAG` bump)

Jicofo and the bridges must run the same release.

1. Upgrade the main host first: `install.sh`, which waits for zero conferences.
2. For each node, re-run `bridge-bundle.sh`. It refuses until main runs the new version.
3. Copy the new bundle to the node.
4. [Drain](#9-remove-or-drain-a-node) the node, then re-run `join.sh`. It refuses while the node carries conferences unless `FORCE=1`.

## 9. Remove or drain a node

**Graceful.** No new conferences go to the node, and it exits when the last one ends:

```bash
cd /opt/talkchief-meet-bridge
docker update --restart=no "$(docker compose ps -q jvb)"   # otherwise Docker restarts it after it exits
curl -s -X POST -H 'Content-Type: application/json' -d '{"graceful-shutdown": "true"}' 127.0.0.1:8080/colibri/shutdown
watch -n 30 "curl -s 127.0.0.1:8080/colibri/stats | grep -o '\"conferences\":[0-9]*'"   # until it exits
docker compose down
```

**Hard.** Use this when the node is gone or broken: `docker compose down`. Jicofo moves its participants to another bridge after a short media gap.

**Revoke on the main host:**

1. Delete the node's line from `/opt/talkchief-meet/bridges.allow`, then run `systemctl reload talkchief-meet-fw`. This is instant.
2. Drop the node from `MONITOR_BRIDGES` and run `docker compose up -d monitor`.
3. Delete the server in Hetzner.

Leave the 5222 publish in place: removing it recreates Prosody, which drops meetings.

**If a node may be compromised, rotate `JVB_AUTH_PASSWORD`:**

1. Revoke the node as above.
2. Set a new value in `/opt/talkchief-meet/.env` (`openssl rand -hex 16`).
3. In a zero-conference window, recreate Prosody, Jicofo and jvb: `docker compose up -d --force-recreate prosody jicofo jvb web`. Prosody re-registers the account from `.env`.
4. Re-bundle and re-join every remaining node.

**Undo the one-time preparation** (zero-conference window):

1. Set `PROSODY_C2S_BIND` back to `127.0.0.1` (or remove it), then run `install.sh`.
2. Run `talkchief-meet-fw remove && systemctl disable talkchief-meet-fw`.
3. Remove `bridges.allow`.

## Octo (optional)

Octo is off today. With it off, a meeting cannot span bridges. To let a big meeting cascade across bridges, set the following on **Jicofo and every jvb together**, in one zero-conference window:

* `ENABLE_OCTO=1`
* `OCTO_BRIDGE_SELECTION_STRATEGY=RegionBasedBridgeSelectionStrategy`
* `JICOFO_OCTO_REGION=fsn1`
* `JVB_OCTO_REGION=fsn1`
* `JVB_OCTO_RELAY_ID=main` (on the main host)

`bridge-bundle.sh` copies `ENABLE_OCTO` and `JVB_OCTO_REGION` from main, and gives each node its own `JVB_OCTO_RELAY_ID`. Re-bundle and re-join the nodes after changing them.

With every bridge in one region, RegionBased keeps a meeting on its first bridge and cascades only when that bridge is overloaded. Relay traffic between bridges uses the public IPs.

To roll back, set `ENABLE_OCTO=0` on Jicofo and every jvb together.

## Sizing nodes

JVB stress is packet-rate based, against a fixed threshold. A small node therefore reports the same stress as the 12 vCPU main host for the same load, and overloads first. After a load test, lower the threshold in the node's `/opt/talkchief-meet-bridge/config/jvb/custom-jvb.conf`. That file is kept on re-join. Restart the jvb only once it is drained.

Independent limit: coturn's relay range (49160-49200) allows only about 40 concurrent relayed participants. Adding bridges does not change that.

## When to add a second shard, and why it is blocked today

A second shard is another web + Prosody + Jicofo set (with its own bridges) behind HAProxy. It is the only way to remove the signalling single point of failure. Even then a shard failure still drops its own live meetings; HAProxy only sends new joins elsewhere. Plan one only when signalling HA becomes a contractual requirement, or concurrency reaches the low thousands.

It is **blocked** until these are fixed:

* **`install.sh` on a fresh host generates a new RS256 keypair** (`jwt/private.pem`). The asap key content changes, so Cowork-signed tokens fail there. The key also derives `TALKCHIEF_EVENTS_SECRET`, so Cowork would reject that shard's room events. Fix: copy `jwt/private.pem` in before the first run, or let `install.sh` take a seed.
* **It also generates a new `TURN_CREDENTIALS`**, which breaks a shared coturn. The same seeding fix applies.
* **Routing must be sticky** on tenant + room for page loads, `/<team>/xmpp-websocket?room=…`, `/<team>/http-bind?room=…` and `/j/<code>`. All room, lobby and wait-for-host state lives in one Prosody's memory.
* **A dead shard never sends `room_destroyed`.** Cowork needs a staleness timeout, and must accept a `room_created` for a room it already considers live.
