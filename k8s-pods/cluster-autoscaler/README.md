# cluster-autoscaler: bridge nodes on Hetzner Cloud

Design 5.8. Kubernetes Cluster Autoscaler `v1.37.0` (released 2026-11-06; its minor must match the
cluster's Kubernetes minor), Hetzner provider, namespace `kube-system`, on a worker.

| Node group | Min:max | Type | Location |
| --- | --- | --- | --- |
| `cowork-jvb-hel` | 1:2 | `cpx22` | hel1 |
| `cowork-jvb-nbg` | 1:2 | `cpx22` | nbg1 |
| `cowork-jvb-fsn` | 0:2 | `cpx22` | fsn1 |

`--balance-similar-node-groups` (ignoring the labels that differ per group), `--scale-down-unneeded-time=10m`.
Workers and control planes belong to no node group, so the autoscaler never adds or removes them;
bridge pods are `safe-to-evict: "false"`, so a node with a running bridge is never removed.

Secret `cluster-autoscaler-hcloud` (`k8s/secret.example.yaml`, placeholders): `token` (Hetzner Cloud
API token) and `cluster-config`, the base64 of:

```json
{
  "imagesForArch": {"amd64": "<Talos snapshot id>"},
  "nodeConfigs": {
    "cowork-jvb-hel": {
      "cloudInit": "<Talos machine config of a bridge node (worker type)>",
      "labels": {"talkchief.io/pool": "cowork-jvb"},
      "taints": [{"key": "talkchief.io/pool", "value": "cowork-jvb", "effect": "NoSchedule"}]
    },
    "cowork-jvb-nbg": {"...": "same"},
    "cowork-jvb-fsn": {"...": "same"}
  }
}
```

The labels and taint must also be in the Talos machine config (`machine.nodeLabels`,
`machine.nodeTaints`) so the kubelet registers them; the autoscaler uses the JSON copy to plan a
scale-up from zero. `HCLOUD_NETWORK` and `HCLOUD_FIREWALL` are overlay placeholders for the Terraform
names. **Unverified until a test cluster:** the JSON field names against the provider's README of
1.37, balancing over the three groups, and node join time (design: 3-4 minutes).
