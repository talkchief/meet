# Porting the Meet pods to GKE (or another provider)

The bases under `k8s-pods/<pod>/k8s` are provider-neutral: plain Kubernetes objects plus KEDA and
Cilium objects, which run on any conformant cluster that has those installed. Everything that only
Hetzner Cloud understands is in one kustomize Component, [`overlays/hetzner`](overlays/hetzner/kustomization.yaml),
which the cluster overlay [`overlays/cowork`](overlays/cowork/kustomization.yaml) includes.
`scripts/test-provider-overlays.py` keeps it that way: it fails when a base renders a Hetzner value,
and with `--baseline REF` it proves the cluster overlay still renders the same objects (the split
itself: the same 42 objects as PR #18's head `4fced601`).

Nothing here has been run on GCP. The GKE column is the equivalent to build and test on a lab
project first; check each against the GKE documentation of the version you deploy.

## What a GKE port adds

1. `k8s-pods/overlays/gcp/kustomization.yaml`: a Component next to `overlays/hetzner`, holding the
   GKE annotations of `meet-haproxy` (below). No Cluster Autoscaler: GKE scales node pools itself.
2. A cluster overlay for the GKE cluster (copy `overlays/cowork`, with `components: [../gcp]`, and
   that cluster's placeholders: KEDA's Prometheus URL; drop the Cluster Autoscaler JSON patch).
3. The bridge sidecar's metadata lookup for GCE (one code change, "Bridges" below).
4. Terraform for the GKE cluster, node pools and firewall rules (outside this repository).
5. A test entry: add the new cluster overlay to `ENTRY_POINTS` in `scripts/test-provider-overlays.py`.

## Mapping

| Hetzner piece (where) | What it does | GKE equivalent |
|---|---|---|
| hcloud CCM annotations on `meet-haproxy` (`overlays/hetzner/meet-haproxy-lb.yaml`): `meet-lb`, lb11, TCP 443/80, targets over the private network, HTTP health check on node port 30080 | the public entry for `meet.talkchief.io`, TLS passthrough to HAProxy | `type: LoadBalancer` gives a regional external passthrough Network Load Balancer (backend-service based with `cloud.google.com/l4-rbs: "enabled"`). TCP passthrough keeps TLS in HAProxy; with `externalTrafficPolicy: Local` GKE health-checks the Service's `healthCheckNodePort`, so only nodes with an HAProxy pod get clients (the 30080 check is not needed). A fixed address: a reserved regional static IP on the Service. No name/type/algorithm annotations. |
| `load-balancer.hetzner.cloud/node-selector: talkchief.io/pool=cowork-wk` | only workers are LB targets | with `externalTrafficPolicy: Local` only nodes running an HAProxy pod pass the check; HAProxy's `nodeSelector` already pins them to the worker pool |
| hcloud Cluster Autoscaler (`cluster-autoscaler/`, provider-bound, composed by `overlays/hetzner`), node groups `cowork-jvb-{hel,nbg,fsn}` | adds/removes bridge nodes (CPX22, Talos image) | node pool autoscaling on the bridge pool (`--enable-autoscaling`, min/max per zone, location policy `BALANCED` for even zones). Keep `--scale-down-unneeded-time` behaviour in mind: GKE's autoscaler profile (`optimize-utilization` or balanced) replaces the flags. Delete the Secret `cluster-autoscaler-hcloud`. |
| node labels `talkchief.io/pool=cowork-wk` / `cowork-jvb` and the bridge taint (set by Talos machine config / node groups) | placement of HAProxy, shards, bridges | node pool `--node-labels` and `--node-taints` with the same keys: the bases select on them unchanged |
| `topology.kubernetes.io/zone` (hcloud CCM: e.g. `hel1-dc2`, region `hel1`) | spreading bridges and shards over sites; alert rules group by it | GKE sets `europe-west3-a` style zones and `europe-west3` regions. The spreads work unchanged. A "site" (hel1/nbg1/fsn1) becomes a zone of one regional cluster, or a region per cluster; `jvb_sidecar.py`'s `zone_site()` (strip `-dcN`) needs the matching rule. |
| **Bridges**: `hostNetwork` + `hostPort` UDP 10000, public IPv4 read from `http://169.254.169.254/hetzner/v1/metadata/public-ipv4` (`meet-jvb/k8s/jvb_sidecar.py` default) | each bridge advertises its node's public address; media goes straight to the node | GKE **Standard** (Autopilot refuses `hostNetwork`/`hostPort`), bridge nodes with external IPs (not a private-node pool). Set `METADATA_URL=http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip` and `ZONE_URL=.../instance/zone` (answers `projects/<n>/zones/<zone>`) in the GCP component, and send the header `Metadata-Flavor: Google` (the code change; host-network pods reach the GCE metadata server directly, not the GKE metadata server). |
| Hetzner Cloud Firewall on the bridge nodes (Terraform): UDP 10000 open, the rest closed | NetworkPolicy cannot guard host-network pods | VPC firewall rule: ingress UDP 10000 from `0.0.0.0/0` to the bridge pool's network tag; GKE adds the LB rules for `meet-haproxy` itself |
| Hetzner private network (`10.0.0.0/8` in `meet-shard/k8s/config/shard.env` `PROSODY_METRICS_ALLOWED_CIDR`) | who may read Prosody metrics | the VPC's node and pod ranges (GKE: the subnet's primary and secondary ranges); a site value, set in the cluster overlay if they fall outside `10.0.0.0/8` |
| Cilium (CNI of the Talos cluster) and the `CiliumNetworkPolicy` in `meet-shard/k8s/networkpolicy.yaml` (node entities) | lets HAProxy/bridges on host network reach the shards | GKE Dataplane V2 is Cilium-based and enforces Kubernetes NetworkPolicy; confirm that your GKE version accepts the Cilium policy CRDs, otherwise rewrite that rule as a NetworkPolicy `ipBlock` on the node subnet |
| `pod-security.kubernetes.io/enforce: privileged` on namespace `meet` | bridges need host networking | the same label on GKE Standard |
| KEDA scaling from the voip cluster's Prometheus | bridge count from conference load | unchanged (install KEDA; the Prometheus URL is a cluster-overlay placeholder already) |

## Not in this repository

The Talos machine configuration, the hcloud CCM and CSI driver, Cilium's Helm values and CoreDNS
placement of the cowork cluster live with the cluster (Cowork repository `pods/overlays/hetzner/cluster`
and Terraform). On GKE they are replaced by the managed control plane, the GCE cloud provider, the
Persistent Disk CSI driver, Dataplane V2 and kube-dns / Cloud DNS.
