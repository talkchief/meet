# meet-namespace: namespace, default deny, relay settings, alerts

- Namespace `meet` (Pod Security `privileged` enforced because the bridges use host networking,
  `restricted` warnings for everything else).
- NetworkPolicy `default-deny` (all ingress and egress) and `allow-dns`; each pod's own policy opens
  only what it needs. Host-network pods (bridges) are outside NetworkPolicy; the Hetzner Cloud
  Firewall guards their nodes.
- ConfigMap `meet-relay` (`k8s/relay.env`): the bridge relay (Octo), off; toggled in the overlay.
- ConfigMap `meet-prometheus-rules` (label `talkchief.io/prometheus-rules: "true"`, file
  `k8s/rules/meet.yml`) for the shared Prometheus of the voip cluster:

| Alert | Fires when |
| --- | --- |
| `MeetShardDown` | a shard out of the HAProxy rotation for 2 minutes |
| `JvbStressHigh` | average bridge stress above 0.8 for 5 minutes |
| `JvbPoolAtMax` | the bridge HPA at its maximum for 15 minutes |
| `JvbPoolBelowMin` | fewer than two bridges, or all in one zone, for 10 minutes |
| `JvbCpuSteal` | a `cowork-jvb` node's CPU steal above 5 % for 10 minutes (node-exporter `node_cpu_seconds_total{mode="steal"}`) |

The rules need kube-state-metrics to export the node labels `talkchief.io/pool` and
`topology.kubernetes.io/zone`, and node-exporter series with a `node` label (monitoring config, not
in this PR).
