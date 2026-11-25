# meet-haproxy: the Meet entry and the load balancer meet-lb

Design 5.7 and the owner's load balancer requirement (2026-11-25). Port of
`feat/ha-shards:deploy/shard/haproxy.cfg.template` (not merged; only its logic is ported).

```
meet.talkchief.io (DNS only) -> Hetzner LB meet-lb (lb11, TCP 443/80, private targets)
  -> node port 30443/30080 on a worker with an HAProxy pod -> HAProxy (TLS ends here)
     /xmpp-websocket, /http-bind -> shard by consistent hash of tenant+room (stick table wins)
     everything else             -> either healthy shard
```

- **StatefulSet of 2** (`meet-haproxy-0/-1`), not a Deployment: HAProxy peers are named in the config
  and each pod must know its own name and reach the other at a stable DNS name (headless Service
  `meet-haproxy-peers`, port 8445). `k8s/start.sh` renders the peers and re-resolves the other pod
  every 10 s, reloading HAProxy when its IP changed (the stick table survives through the local
  peer). Required anti-affinity: different workers. PDB `minAvailable: 1`.
- **Image:** `docker.io/library/haproxy:2.8.31@sha256:f9e6…` (2.8.32 was a day old when pinned).
- **TLS: in HAProxy**, from the `kubernetes.io/tls` Secret `meet-tls` (SOPS or cert-manager), so the
  load balancer passes TCP through and needs no certificate. Port 80 redirects to HTTPS.
- **Load balancer `meet-lb`**, created by the hcloud cloud-controller-manager from the Service
  annotations (`k8s/services.yaml`). Names checked against the CCM reference at commit
  `e872d8f5` (`hcloud-lb-annotations.txt`); `health-check-port` is a port on the targets (CCM
  `internal/lbspec/opts.go`), hence the fixed node port 30080:

  | Annotation | Value |
  | --- | --- |
  | `name` / `type` | `meet-lb` / `lb11` |
  | `use-private-ip` | `"true"` (targets the workers over the private network) |
  | `node-selector` | `talkchief.io/pool=cowork-wk` |
  | `protocol` | `tcp` (passthrough on 443 and 80) |
  | `health-check-protocol` / `-port` / `-http-path` | `http` / `30080` / `/talkchief-haproxy-health` |
  | `health-check-interval` / `-timeout` / `-retries` | `5s` / `3s` / `2` |
  | `network-zone` | `eu-central` |

  `externalTrafficPolicy: Local`: a worker without an HAProxy pod fails the check and gets no
  clients. The check also fails while HAProxy reaches no shard and in its first 30 s (empty stick
  table until the peer resyncs).
- **No stickiness at the load balancer**, on purpose: both HAProxy pods compute the same consistent
  hash over the same shard list (same names and ids) and share the peered stick table, so a room goes
  to the same shard whichever HAProxy pod or load balancer target receives the connection. Sticky
  sessions would add nothing and would pin a client to a dead target longer.
- **WebSockets:** `/xmpp-websocket` is a plain TCP stream at the load balancer; HAProxy keeps it with
  `timeout tunnel 1h` (Prosody pings about every minute) and `timeout client/server 90s` (above the
  60 s BOSH long poll). This also covers the missing `proxy_read_timeout` noted in Cowork's
  KNOWLEDGE.md for the old path.
- **Logs** carry the path and the room key, never the query string (it holds the JWT).
- **Metrics:** HAProxy's Prometheus exporter on 8404 (not in the load balancer Service); the
  `MeetShardDown` alert reads `haproxy_server_status`.

**Unverified until a test cluster:** the CCM health check on node port 30080, peer resync after a pod
restart, and the client address (no PROXY protocol yet: HAProxy sees the load balancer's address).
