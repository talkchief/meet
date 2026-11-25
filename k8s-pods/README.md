# Meet on Kubernetes: pod artifacts

Kubernetes manifests and image recipes for TalkChief Meet (Jitsi, docker-jitsi-meet `stable-11248-2`)
on the `cowork` cluster, following the cowork cluster design (talkchief/kz5
`doc/collaboration_cluster_architecture.md`, version 3: sections 5.6-5.9, 6.1, 8, 9, 10.2) and kz5's pod
conventions (`doc/pod_artifacts.md`). **Nothing here is deployed** and no cluster exists yet. The host
install under `deploy/` is unchanged and stays the production path until the migration.

The directory is `k8s-pods/`, not kz5's `pods/`: this repository's `.gitignore` ignores `Pods/` (iOS
CocoaPods), which also matches `pods/` on case-insensitive checkouts (Windows, macOS). Inside it the
layout is kz5's: `<name>/{image/,k8s/,README.md}`.

## Pods

| Pod | What | Image |
| --- | --- | --- |
| [`meet-namespace`](meet-namespace/README.md) | namespace `meet`, default-deny NetworkPolicy plus DNS, the bridge relay settings (`meet-relay`, off), the Meet alert rules | none |
| [`meet-web`](meet-web/README.md) | image recipe only: the branded web (`deploy/web`) on the upstream base pinned by digest | `ghcr.io/talkchief/meet-web:<12-hex commit>` |
| [`meet-shard`](meet-shard/README.md) | `meet-shard-0` and `meet-shard-1`: web + Prosody (TalkChief modules) + Jicofo, one pod each, on different workers, one Service each | meet-web; upstream prosody, jicofo by digest |
| [`meet-haproxy`](meet-haproxy/README.md) | two HAProxy pods routing rooms to shards (port of `feat/ha-shards`), behind the Hetzner Load Balancer `meet-lb` | upstream haproxy 2.8.31 by digest |
| [`meet-asap`](meet-asap/README.md) | RS256 public-key server for Prosody | upstream nginx-unprivileged by digest |
| [`meet-events`](meet-events/README.md) | room events to Cowork, call diagnostics | upstream nginx-unprivileged by digest |
| [`meet-jvb`](meet-jvb/README.md) | video bridges: host network UDP 10000, one per bridge node, graceful drain on scale-in, KEDA autoscaling | upstream jvb by digest; upstream python sidecar by digest |
| [`cluster-autoscaler`](cluster-autoscaler/README.md) | Cluster Autoscaler, Hetzner provider, node groups `cowork-jvb-{hel,nbg,fsn}` (CPX22) | upstream by digest |
| [`overlays/cowork`](overlays/cowork/kustomization.yaml) | composes every base for the cowork cluster; holds the placeholders and the relay toggle | |

Upstream images that carry no TalkChief code run at an exact tag pinned by digest, with TalkChief code
(Prosody modules) and settings mounted from Kustomize-generated ConfigMaps (kz5 "cluster tooling"
exception). Only `meet-web` is built by us. Every digest was read from its registry on 2026-11-25.

## Apply order

Argo CD (shared, voip cluster) applies `k8s-pods/overlays/cowork`. The order inside it, and the order for
a first manual bring-up on a test cluster:

1. Operators and cluster pieces this PR assumes: Cilium (with CiliumNetworkPolicy), the hcloud
   cloud-controller-manager, KEDA, kube-state-metrics with node labels, the Prometheus agent.
2. `meet-namespace`, then the Secrets from each pod's `secret.example.yaml` (SOPS; placeholders here).
3. `meet-asap`, `meet-events`.
4. `meet-shard` (needs the meet-web image built and its tag set in `meet-shard/k8s/kustomization.yaml`).
5. `meet-haproxy` (creates `meet-lb`; point `meet.talkchief.io` at it in Terraform/DNS).
6. `cluster-autoscaler`, then `meet-jvb` (the bridge pods wait Pending until the autoscaler adds nodes).

## Test

```sh
python3 scripts/test-k8s-pods.py
```

Offline (PyYAML only; no kubectl, kustomize or container runtime): follows every kustomization from
the overlay, checks pins, resources, probes, placement, the load balancer, routing, bridges,
autoscaling, NetworkPolicies, alerts, TURN/STUN, drift of the copied `deploy/` files, the absence of
secrets, and runs the bridge sidecar's drain against a stand-in bridge. Known gaps are printed as
`GAP` lines and do not fail the run.

## What this does not do

- No infrastructure: servers, private network, Cloud Firewalls (UDP 10000 on bridge nodes, 443/80 to
  `meet-lb` only), DNS (`meet.talkchief.io`, `turn1/2/3.talkchief.io`) and the Talos image are
  Terraform's. The Talos machine config of the bridge nodes goes into the autoscaler's Secret.
- The workers' Talos machine config must let the kubelet accept the shards' unsafe sysctl
  `net.ipv4.tcp_retries2` (`KubeletConfig.config.allowedUnsafeSysctls: [net.ipv4.tcp_retries2]`, the
  same allowance Cowork's app pods need): without it the shard pods are refused (`SysctlForbidden`).
  It makes Prosody drop a dead bridge within seconds (bridge loss, k8s-pods/meet-shard/README.md).
- KEDA, the hcloud CCM, Cilium and the monitoring agent are assumed installed; none is in this PR.
- coturn (TURN on the three workers) is in the Cowork PR (namespace `media`); Meet only lists it.
- No image was built: there is no container runtime on the machine that wrote this.
- No change to `deploy/` or to the host install; `feat/ha-shards` is not merged, only ported.

## Open items

- Build and push `meet-web`, then set its tag and digest (`000000000000` placeholder).
- KEDA's Prometheus address (shared voip Prometheus reachable from this cluster) and, if needed, its
  authentication; Terraform names for `HCLOUD_NETWORK` / `HCLOUD_FIREWALL` (overlay placeholders).
- Check on a test cluster what can only be checked live: the JVB metric names, that the Jitsi images
  run as uid 1000 with a read-only root, the `custom-jvb.conf` / `custom-jicofo.conf` keys, that the
  bridge channel needs no colibri websocket, the `GLOBAL_CONFIG` external_services override, the
  hcloud health check on node port 30080, and the Cluster Autoscaler's balancing over the three groups.
- Client addresses: `meet-lb` passes TCP without the PROXY protocol, so HAProxy and Prosody see the
  load balancer's address (as with `feat/ha-shards`). Enabling `uses-proxyprotocol` with
  `accept-proxy` and the `hostname` annotation is a follow-up once tested.
- `meet-lb` is one Hetzner Load Balancer in one location: losing that location loses the entry.
- In-cluster traffic to Cowork (`cowork-app.cowork.svc:8065`) is plain HTTP; it was TLS over the
  private network. Cilium transparent encryption, if the owner wants it, covers it.
- Cowork needs a staleness timeout for rooms (a lost shard never sends `room_destroyed`, gate G11).
- Rotate the Meet TURN secret as it moves (gate G12); every Secret is generated fresh.
- Raise the bridge maximum (4) only after a test at that size; `MAX_BRIDGE_PARTICIPANTS` is 15 per shard
  (about 30 per CPX22 bridge with two shards, test cluster 2026-11-25).
