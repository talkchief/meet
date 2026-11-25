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
  at the bridge's participant count, so the Deployment removes the emptiest bridge.
- **Scale-in keeps the sites (L18):** the init container reads the node's site (`hel1`, `nbg1`,
  `fsn1`) from `http://169.254.169.254/hetzner/v1/metadata/availability-zone`; the sidecar marks its
  pod with the annotation `talkchief.io/bridge-site`, lists the other bridge pods and adds 1,000,000 to
  the deletion cost while no other live bridge has its site. The ReplicaSet therefore removes a bridge
  of a site that keeps another one first, and takes a site's last bridge only when every site has one
  bridge left: a 4 -> 2 scale-in ends in two sites. (The zone spread acts only at scheduling; before
  this both survivors of M3's scale-in were in hel1, test cluster 2026-11-25.) A bridge whose site
  cannot be read still runs and simply never counts as a site's last.
- **Drain:** on deletion the
  sidecar's preStop enables drain (`POST /colibri/drain/enable`: Jicofo stops placing conferences
  there), waits until no participant is left, then calls `POST /colibri/shutdown
  {"graceful-shutdown":"true"}` and waits for the bridge to finish; the jvb container's preStop waits
  for that. `terminationGracePeriodSeconds: 10800` (3 h); a meeting still running then is moved by
  Jicofo. Liveness is TCP only, so a draining bridge is never restarted. Pods carry
  `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`.
- **Least privilege for the sidecar:** ServiceAccount `meet-jvb` with get/list/patch on pods in `meet`
  (RBAC cannot name a random pod; list reads the other bridges' sites), narrowed by the
  ValidatingAdmissionPolicy `meet-jvb-own-pod-only` to changing its own pod (the pod name bound into
  its token) and only the deletion-cost and `talkchief.io/bridge-site` annotations. The
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

Metric names checked on the test cluster (2026-11-25): `jitsi_jvb_stress` and
`jitsi_jvb_current_endpoints` (participants). **Unverified until a test cluster:** that `/init` is the image's entrypoint and the HOCON
keys in `custom-jvb.conf`.

**Measured on the test cluster (2026-11-25, every participant's camera on, 4-person meetings, 360p delivered):**
- Adding bridges scales linearly: 1 -> 2 -> 3 bridges carried 6 -> 12 -> 18 meetings (24 -> 48 -> 72 attendees) at a
  flat mean stress (0.45, 0.42, 0.49) with unchanged quality and join time (2.4-3.4 s to media); Jicofo, Prosody,
  HAProxy and the workers did not grow measurably. KEDA added each bridge when the maximum allowed it; with no free
  bridge node the Cluster Autoscaler's node made it 2 min 45 s from decision to a serving bridge.
- One CPX22 bridge held 36 all-video attendees at stress 0.49 with full quality; stress 0.8 extrapolates to about 45.
  CPX22 stress varies about 0.1 between hosts at equal load, so judge the pool's mean stress.
- A real scale-in drained the emptiest bridge (deletion cost 16 against 32): its 4 meetings kept every member and
  their video, new meetings went to the other bridge, and the pod exited 81 s after its last meeting ended; the
  Cluster Autoscaler removed the empty node 10 minutes later.
- `max-bridge-participants` (15 per shard) is soft: with every bridge over it Jicofo still placed conferences by
  stress (20 from one shard on one bridge), so stress and autoscaling are the real protection.
