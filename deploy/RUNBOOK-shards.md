# Meet shards: survive the loss of a meeting host

One meeting host (Prosody, Jicofo, web) is a single point of failure: if it
goes down, every meeting goes down, however many bridges there are. Shards
remove that: each shard is a complete signalling stack on its own host, a
meeting lives on exactly one shard, and the bridges serve every shard. If a
shard host dies, only its meetings drop, and their participants reconnect to
a remaining shard within seconds.

Default off. A host without `/opt/talkchief-meet/shards.list` runs exactly as
before (`install.sh` does not touch HAProxy, ports or firewalls for shards).

```
 meet.talkchief.io ──► load balancer (Hetzner LB, TCP 443, health check
                       https://<host>/talkchief-haproxy-health)
          ┌──────────────────────┴──────────────────────┐
     shard A host                                  shard B host
     HAProxy :80/:443 (TLS)                        HAProxy :80/:443 (TLS)
       XMPP of room R → hash("<tenant>/R") → the same shard from either host
       page, static files, guest links → any healthy shard
     web (10.1.0.44:8443), Prosody, Jicofo,        web (10.1.0.Y:8443), Prosody,
     coturn, asap, events, monitor, local jvb      Jicofo, coturn, ... local jvb
          └─────── bridges: XMPP_SERVER lists every shard's Prosody ───────┘
```

## How it works

- **Routing.** Every shard host runs the same HAProxy config
  (`shard/haproxy.cfg.template`, rendered by `install.sh` from
  `shards.list`). XMPP requests (`/xmpp-websocket?room=`, `/http-bind?room=`,
  with an optional `/<tenant>/` prefix) are sent by a consistent hash of
  `/<tenant>/<room>`; each server's id is derived from its address, so every
  HAProxy computes the same shard for a room whatever the order of
  `shards.list`. All other requests go to any healthy shard (every shard
  serves the same pages).
- **Health.** HAProxy checks each shard's web every 2 s:
  `/talkchief-shard-health` (web → Jicofo's REST API) and `/http-bind`
  (web → Prosody). Two failures mark the shard down and cut its sessions;
  its rooms then hash to the remaining shards and clients reconnect there.
  HAProxy refuses `/talkchief-shard-health` from clients.
- **Secrets are shared.** All shards use the same JWT key pair (Cowork signs
  one token for any shard), the same XMPP component passwords (each bridge
  logs in to every shard with one password) and the same TURN secret.
  `install.sh` never regenerates a secret that exists, so a new shard is
  seeded with them (`shard-bundle.sh` / `shard-join.sh`) before its first
  install.
- **Per-host settings** live in `/opt/talkchief-meet/host.env` (this shard's
  addresses, `MONITOR_BRIDGES`) and are applied after the managed block, so
  they win over `env.talkchief`. In shard mode `install.sh` also sets
  `COMPOSE_FILE` (adds `docker-compose.shard.yml`) and moves the web
  container to `SHARD_PRIVATE_IP:8000/8443`.
- **Firewalls.** `talkchief-meet-shard-fw` (`meet-fw.sh --role shard`) lets
  only the hosts in `shards.list` reach the web's private 8443. Prosody 5222
  stays limited to `bridges.allow` (every shard needs every bridge listed).
  On bridges, 8080 is open to `MAIN_PRIVATE_IP` and every `SHARD_PRIVATE_IPS`.
- **Cowork** needs no change: it links to `meet.talkchief.io` and receives
  room events from whichever shard hosts the room.
- **TURN.** Each shard's coturn relays on that shard's public IP and accepts
  the shared secret. Give `turn.talkchief.io` an A record per shard.

## One-time preparation (first shard, zero conferences)

On the existing meeting host (it becomes shard A; a one-shard setup runs
through HAProxy and behaves as before):

1. Bridges already need `PROSODY_C2S_BIND` on the private IP
   (RUNBOOK-bridge-node.md, one-time preparation).
2. Create the per-host file and the shard list:
   ```bash
   cat > /opt/talkchief-meet/host.env <<'EOF'
   SHARD_NAME=shard-a
   SHARD_PRIVATE_IP=10.1.0.44
   PROSODY_C2S_BIND=10.1.0.44
   EOF
   echo "10.1.0.44 shard-a" > /opt/talkchief-meet/shards.list
   ```
   The web certificate must be in `<CONFIG>/web/keys/cert.{crt,key}`
   (HAProxy terminates TLS with it).
3. `cd /opt/talkchief-meet-src && git pull --ff-only && bash deploy/scripts/install.sh`
   (waits for zero conferences; recreates web on 8443 and starts HAProxy on
   443; the brief web restart is the only interruption).
4. Check: `curl -sk https://127.0.0.1/talkchief-haproxy-health` → 200,
   `docker compose logs haproxy` shows `shards_xmpp/shard-a` for requests, a
   test meeting works.

## Add a shard

1. **Server**: same private network as the other meeting hosts, Cloud
   Firewall with inbound TCP 80/443 and UDP 10000 (its local jvb) and the
   TURN ports, sshd on the private IP only, Docker + compose.
2. **Bundle** on an existing shard (from its deploy checkout):
   `deploy/scripts/shard-bundle.sh <private-ip> <public-ip> <name>`.
   It adds the shard to this host's `shards.list` and writes
   `/root/shard-<name>.tgz` (all Meet secrets: treat it like the host).
3. **Copy and join** over the private network:
   ```bash
   scp /root/shard-<name>.tgz root@<private-ip>:/root/
   ssh root@<private-ip> 'tar -xzf /root/shard-<name>.tgz -C /root && /root/talkchief-meet-shard/shard-join.sh'
   ```
   `shard-join.sh` seeds the secrets, installs from the bundled checkout and
   checks Jicofo, the shard health page and HAProxy.
4. **Same shard list everywhere**: copy `/opt/talkchief-meet/shards.list` to
   every other shard host and run `install.sh` there. HAProxy reloads in
   place (no connection drops); anything else `install.sh` finds changed is
   restarted only under its usual zero-conference rule, so run it outside
   working hours.
5. **Bridges**: on the bundling shard run `bridge-bundle.sh` again for every
   bridge and `join.sh` on each (it drains the bridge gracefully first); the
   bridge then joins every shard. Add every bridge to `bridges.allow` on the
   new shard (the bundle copied the list) and `systemctl reload
   talkchief-meet-fw`.
6. **Entry**: add the new host to the load balancer (TCP 443, health check
   `https /talkchief-haproxy-health`) and to `turn.talkchief.io`.
7. **Verify**: open two test meetings with different names; HAProxy logs
   (`docker compose logs haproxy`) show both shards in use; each bridge's
   `/colibri/stats` shows conferences from both.

## Remove or drain a shard

1. Take the host out of the load balancer (no new clients reach its HAProxy;
   the other shards' HAProxy still route rooms to it).
2. Remove its line from `shards.list` on every **other** shard and run
   `install.sh` there: new joins for its rooms now go elsewhere. Wait until
   its Jicofo reports zero conferences (`curl -s 127.0.0.1:8888/stats`).
3. Re-bundle and re-join the bridges without it, then stop the host
   (`docker compose down`).

## Failure behaviour (validated on test VMs, see the Cowork repo's
`architecture/ha/rehearsal/meet-shards/`)

- **Shard host down**: HAProxy marks it down within ~4 s (2 failed checks at
  2 s) and closes its sessions. Its meetings drop; participants' clients
  reconnect and land on another shard (same room name, new conference).
  Meetings on other shards are untouched.
- **Bridge down**: Jicofo moves the affected conferences to another bridge
  (media interruption of a few seconds).
- **HAProxy down on one host**: the load balancer's health check fails and it
  stops sending clients there; the other hosts' HAProxy still reach this
  shard's web.

## Rollback to a single meeting host

On the shard that stays: `rm /opt/talkchief-meet/shards.list` (keep or delete
`host.env`), run `install.sh` (zero conferences): HAProxy is removed, web
returns to 443, the shard firewall unit stays installed but is no longer
needed (`talkchief-meet-fw --role shard disable` removes the Docker
dependency, `--role shard remove` the rules). Point `meet.talkchief.io` back at
the host, re-join the bridges with a single `XMPP_SERVER`.

## Limits

- A meeting lives on one shard; a shard failure restarts its meetings (no
  live migration in Jitsi).
- A Jicofo that runs but has lost its XMPP connection still answers the
  REST health; Jicofo reconnects on its own. Enable
  `JICOFO_ENABLE_HEALTH_CHECKS=1` and point the check at `/about/health` if
  that case matters.
- Upgrades: upgrade one shard at a time (drain it from the LB first); all
  shards and bridges must run the same `VERSION`.
