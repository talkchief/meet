# meet-events: room events and call diagnostics

The compose service `events` on Kubernetes: two small nginx pods (`nginxinc/nginx-unprivileged:1.30.6-alpine3.24`
pinned by digest, non-root, read-only root). `k8s/events.conf` is the Kubernetes variant of
`deploy/events/events.conf`:

- room events from Prosody (`mod_talkchief_room_events`, HMAC-signed) go to Cowork's in-cluster Service
  `cowork-app.cowork.svc.cluster.local:8065` with `Host: cowork.talkchief.io` (was `https://10.1.0.46`);
- call diagnostics from meeting pages (rate-limited as before) are written as JSON lines to stdout,
  so Alloy keeps them in Loki, instead of a file per day on the host (the 14-day retention becomes
  Loki's).

NetworkPolicy: in from the shard pods only, out to namespace `cowork` port 8065 only.
