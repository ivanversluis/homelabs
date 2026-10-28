# Kubernetes PVC capacity, usage and Discord alerts

## Purpose

The OpenClaw PVC ran out of filesystem space despite functioning node monitoring.
The managed **Kubernetes / Kubernetes PVC Capacity & Usage** dashboard provides a
per-claim view of requested Kubernetes capacity and actual filesystem usage.
No PVC size is changed by this implementation.

## Data contract

Grafana uses the **standalone observability Prometheus** (UID `prometheus`),
not the kube-prometheus-stack Prometheus in `monitoring`.

- `kube_persistentvolumeclaim_resource_requests_storage_bytes` (job `kube-state-metrics`):
  requested PVC bytes; available even if a PVC is not mounted.
- `kubelet_volume_stats_capacity_bytes`, `used_bytes`, `available_bytes`:
  mounted PVC filesystem metrics from kubelet `/metrics`, fetched through
  authenticated Kubernetes API proxy on each node.
- Filesystem fullness uses `100 * (1 - available/capacity)`, which tracks
  inability to write (including reserved blocks) better than used/capacity.
- `kubelet_volume_stats_inodes{,_used}` shows inode pressure separately.
- An absent metric is **not** interpreted as zero. Unmounted PVCs can have no
  kubelet volume metrics. The dashboard lists running pod PVCs with missing stats.
- These do not measure Longhorn replica data, snapshots or physical overhead.

## Alerts

Grafana-managed, provisioned into `Homelab/pvc-capacity`; routed through the
existing `discord-primary` contact point and Vault-backed webhook.

| Rule | Condition | Duration |
| --- | --- | --- |
| PVCFilesystemUsageHigh | filesystem full >80% | 15m |
| PVCFilesystemUsageCritical | filesystem full >95% | 2m |
| PVCMountedVolumeMetricsMissing | Running pod's PVC has no kubelet stats | 10m |
| PVCKubeletScrapeUnavailable | individual kubelet scrape `up == 0` | 5m |

The Discord template displays namespace and PVC, in addition to node and
instance if available. Existing node alerts are unchanged.

## NetworkPolicy

The Grafana pod is permitted direct external HTTPS TCP/443, excluding RFC1918
destinations, for the Discord webhook. DNS and same-namespace access remain
covered by existing policy. The IP block is not restricted to Discord alone;
Kubernetes NetworkPolicy cannot natively resolve FQDN egress rules. If strict
destination-bound egress is required, migrate this rule to a Calico domain policy
after DNS/IP validation.

Note: Alertmanager in the separate `monitoring` namespace is **not** used for
these rules. The current Discord receiver is Grafana unified alerting.

## Validation after merging

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization observability -n flux-system --with-source
kubectl -n observability rollout status deploy/prometheus
kubectl -n observability rollout status deploy/grafana
kubectl -n observability get netpol allow-grafana-discord-https
```

In Grafana Explore using Prometheus, run:

```promql
count(up{job="kubernetes-kubelet-volumes"})
```

```promql
kubelet_volume_stats_capacity_bytes{job="kubernetes-kubelet-volumes",namespace="openclaw",persistentvolumeclaim="openclaw-data"}
```

```promql
kubelet_volume_stats_used_bytes{job="kubernetes-kubelet-volumes",namespace="openclaw",persistentvolumeclaim="openclaw-data"}
```

Compare with `kubectl -n openclaw exec deploy/openclaw -- df -h
/home/node/.openclaw`. Metric values can differ slightly by scrape timing
and reserved filesystem blocks.

Verify **Grafana → Alerting → Alert rules → Homelab → pvc-capacity** and
**Contact points → discord-primary → Test**. Observe the message arrive and
then run a controlled synthetic firing/resolved alert as documented in
[Node resource alerting](node-resource-alerting.md). Review Grafana logs
and external egress if the Discord test fails. Live telemetry and actual
delivery cannot be verified through the Git repository alone.

If the custom dashboard is empty, inspect `/targets` on standalone Prometheus,
node/API proxy scrape `up`, and Kubernetes ServiceAccount `nodes/proxy` RBAC.
PVC metrics depend on kubelet/CSI support, so visibility is not guaranteed
for every volume driver.
