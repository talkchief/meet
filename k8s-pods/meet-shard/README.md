# meet-shard: two Meet signalling shards

Design 5.7. Each shard is one Deployment with one pod (`meet-shard-0`, `meet-shard-1`) holding:

| Container | Image | Requests / limits | Probes |
| --- | --- | --- | --- |
| `web` | `ghcr.io/talkchief/meet-web` (k8s-pods/meet-web) | 50m / 128Mi, 500m / 256Mi | HTTP `/config.js` on 8000 |
| `prosody` | `ghcr.io/jitsi/prosody:stable-11248-2@sha256:47a2…` | 100m / 256Mi, 1 / 512Mi | BOSH `/http-bind` on 5280 |
| `jicofo` | `ghcr.io/jitsi/jicofo:stable-11248-2@sha256:cedb…` | 200m / 768Mi, 1 / 1Gi | REST `/stats` on 8888 |

An init container (meet-web image) puts the web settings into the web container's `/config` as
`deploy/scripts/install.sh` does on a host (versioned branding URL included) and copies
`custom-jicofo.conf` into Jicofo's `/config`.

- **Placement:** workers only (`talkchief.io/pool: cowork-wk`); required anti-affinity against any
  other shard pod per node, so the two shards are on different workers. `Recreate`: never two pods
  of one shard (a shard being replaced leaves HAProxy's rotation and its rooms come back on the
  other shard, about 45 s in the Cowork rehearsal).
- **Services:** `meet-shard-0` / `meet-shard-1`, ClusterIP, web 80 and XMPP 5222. HAProxy uses the
  web port; every bridge connects to both on 5222 (only from bridge nodes: CiliumNetworkPolicy).
- **Settings** (`k8s/config/`, generated ConfigMaps):
  - `plugins/*.lua`, `custom-config.js`, `custom-interface_config.js`: byte copies of `deploy/`
    (the test fails when they drift; copy again after changing `deploy/`);
  - `shard.env`: `deploy/env.talkchief` with only the listed Kubernetes changes (auth, JWT, lobby,
    guest rules unchanged; the test compares every key);
  - `custom-meet.conf`: Kubernetes variant of `deploy/web/custom-meet.conf`: Cowork at
    `cowork-app.cowork.svc.cluster.local:8065` (Host `cowork.talkchief.io`), kube-dns, the
    `meet-events` Service, and the shard health page from `feat/ha-shards` (Jicofo REST in the pod);
  - `custom-config.k8s.js`: appended to custom-config.js: P2P STUN on turn1/2/3;
  - `custom-jicofo.conf`: `max-bridge-participants = 15` (per shard: two shards fill a CPX22 bridge to
    about 30, measured on the test cluster 2026-11-25) and
    `max-bridge-participants-per-interval = 30`.
- **TURN/STUN:** Prosody's `external_services` lists, for each of `turn1/2/3.talkchief.io`, `stun:`
  3478, `turn:` 3478 UDP and TCP and `turns:` 443, with time-limited (12 h) credentials derived from
  the Meet secret (`turn-meet`); a client gets all three servers, so one lost worker does not break a
  meeting. The image's template takes one STUN host only, so `GLOBAL_CONFIG` sets the full list.
- **Secrets** (`k8s/secret.example.yaml`, placeholders): `meet-jicofo-auth`, `meet-jvb-auth`,
  `turn-meet`, `meet-events`, `ghcr-pull`, plus `meet-jwt-public` (k8s-pods/meet-asap). The events key
  must equal what Cowork uses to verify (install.sh derives it as
  `sha256("talkchief-meet-events-v1:" + private.pem)`; the Cowork PR owns `meet-events` there).

**Unverified until a test cluster:** that the Jitsi images start as uid 1000 with read-only roots and
`drop: [ALL]`, the `GLOBAL_CONFIG` override, the Jicofo HOCON keys, and that nginx resolves
`kube-dns.kube-system.svc.cluster.local` at start.
