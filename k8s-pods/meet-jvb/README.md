# meet-jvb: video bridges and their autoscaling

Design 5.8, with the owner's change to CPX22 bridge nodes (2026-11-25).

- **Placement:** only on `talkchief.io/pool: cowork-jvb` nodes (tolerates their `NoSchedule` taint),
  one per node (required anti-affinity on hostname, and the host port), spread over zones.
- **Network:** host networking, media on **UDP 10000** of the node. The init container reads the
  node's public IPv4 from `http://169.254.169.254/hetzner/v1/metadata/public-ipv4` and the bridge
  starts with `JVB_ADVERTISE_IPS` set to it; STUN is off (`JVB_DISABLE_STUN=1`). **The bridge needs no
  TURN itself**: clients that cannot reach UDP 10000 relay through coturn on the workers
  (turn1/2/3), and the bridge simply answers the relay's address.
- **Signalling:** `XMPP_SERVER` lists both shards' Prosody Services
  (`meet-shard-{0,1}.meet.svc.cluster.local:5222`), so one pool serves both shards.
- **REST on loopback only** (`custom-jvb.conf`): colibri stats, drain and graceful shutdown on
  127.0.0.1:8080. The sidecar serves `/metrics` alone on 9888 for Prometheus.
- **Resources (CPX22, 2 vCPU / 4 GB):** requests 1.5 CPU / 2.5 GiB, memory limit 3 GiB, **no CPU
  limit** (throttling a media forwarder shows as jitter), Java heap `VIDEOBRIDGE_MAX_MEMORY=1536m`.
  The rest of the node is for Talos, Cilium, node-exporter and Alloy. Load measurement stays at the
  release default (`cpu-usage`, CPU steal detection on).
- **Scale-in without cutting a meeting:** the sidecar keeps `controller.kubernetes.io/pod-deletion-cost`
  at the bridge's participant count, so the Deployment removes the emptiest bridge. On deletion the
  sidecar's preStop enables drain (`POST /colibri/drain/enable`: Jicofo stops placing conferences
  there), waits until no participant is left, then calls `POST /colibri/shutdown
  {"graceful-shutdown":"true"}` and waits for the bridge to finish; the jvb container's preStop waits
  for that. `terminationGracePeriodSeconds: 10800` (3 h); a meeting still running then is moved by
  Jicofo. Liveness is TCP only, so a draining bridge is never restarted. Pods carry
  `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`.
- **Least privilege for the sidecar:** ServiceAccount `meet-jvb` with get/patch on pods in `meet`
  (RBAC cannot name a random pod), narrowed by the ValidatingAdmissionPolicy `meet-jvb-own-pod-only`
  to its own pod (the pod name bound into its token) and to the deletion-cost annotation only. The
  token is mounted into the sidecar only, never into the bridge.
- **Autoscaling (`scaledobject.yaml`, KEDA):** min 2, max 4; add a bridge when the average stress
  stays above 0.5 for 2 minutes or when there are more than 18 participants per bridge; shrink only
  after 30 minutes below 0.2, one bridge per 15 minutes. The Cluster Autoscaler (k8s-pods/cluster-autoscaler)
  adds the node a pending bridge needs.
- **Bridge relay (Octo): prepared, off.** `ENABLE_OCTO`, region `eu` and the Jicofo strategy
  `IntraRegionBridgeSelectionStrategy` come from the `meet-relay` ConfigMap
  (k8s-pods/meet-namespace/k8s/relay.env); each bridge's relay id is its pod name. The one toggle is in
  the overlay (`k8s-pods/overlays/cowork`, `ENABLE_OCTO=false`); the test cluster turns it on for the
  large-meeting test. Relay traffic uses the same UDP 10000.
- **NetworkPolicy does not cover host-network pods.** The Hetzner Cloud Firewall (Terraform) must
  open only UDP 10000 on the bridge nodes from the internet; 9888 is for the private network only.

**Unverified until a test cluster:** the metric names `jitsi_jvb_stress_level` and
`jitsi_jvb_participants`, that `/init` is the image's entrypoint, the HOCON keys in
`custom-jvb.conf`, and a full drain on a real scale-in.
