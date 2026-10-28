# Longhorn replica scheduling, capacity and Discord alerting

## Why this exists

Kubernetes `Ready` and node root usage cannot establish that Longhorn can place
new replicas. Longhorn has independent Node and Disk `Ready`, `Schedulable`,
and scheduling-permission conditions. With three storage-labelled workers and
two replicas per StorageClass, loss of one schedulable node leaves only two
placement candidates, removing rebuild/failure headroom. The existing PVC
capacity dashboard answers a different question: *how full is each mounted PVC
filesystem?*

## GitOps ownership

Longhorn itself is managed by `compute/eliteboxes/platform/longhorn-kustomization.yaml`.
New scoped ingress policy `platform/storage/longhorn/k8s/monitoring-prometheus-netpol.yaml`
permits ONLY the `observability` namespace's `app.kubernetes.io/name=prometheus`
pods to access `app=longhorn-manager` on TCP 9500. The port hosts both Longhorn
`/metrics` and its manager API; do not loosen the pod/namespace matchers.

The standalone `observability` Prometheus (Grafana datasource UID `prometheus`)
gets a `longhorn-manager` job using Kubernetes `endpoints` discovery, filtered
to the `longhorn-backend` service's named `manager` port. This scrapes every
manager separately, unlike a load-balanced ClusterIP request. Scrapes run every
30 seconds. The separate kube-prometheus-stack server in `monitoring`
is not configured by this scrape job.

The managed dashboard is **Kubernetes / Longhorn Scheduling & Disk Capacity**
(`k8s-longhorn-scheduling`). It adds drill-down from the home page,
Kubernetes Platform Overview, and Kubernetes Node Resource Capacity. The
home page and node resource page also show schedulable node count and
unschedulable disk count.

## What the metrics mean

| Metric | Meaning |
| --- | --- |
| `longhorn_node_status{condition="ready"}` | Ready for Longhorn work |
| `longhorn_node_status{condition="schedulable"}` | Node schedulable, not cordoned |
| `longhorn_node_status{condition="allowScheduling"}` | Longhorn admin allows replicas |
| `longhorn_disk_status{condition="schedulable"}` | Can schedule replicas on this disk |
| `longhorn_disk_status{condition="ready"}` | Disk is ready |
| `longhorn_disk_capacity_bytes` | Physical disk capacity reported by Longhorn |
| `longhorn_disk_usage_bytes` | Physical disk usage, **including non-Longhorn data** |
| `longhorn_disk_reservation_bytes` | Space reserved for other workloads/system |
| `longhorn_volume_robustness{state="degraded"}` | Value 1 for degraded, 0 otherwise |
| `up{job="longhorn-manager"}` | Scrape success, one target per manager endpoint |

Node eligibility requires ALL three Longhorn node conditions true and at least
one disk both Ready and Schedulable. The dashboard's eligibility metric is
cluster-wide; table and disk charts can be filtered by node. An empty result
is not a healthy zero. Longhorn `condition_reason` is shown when supplied.

**Warning about 75%:** The cluster's observed setting is described as a
25% minimum-free-space threshold; this cannot be interpreted as an exact
`longhorn_disk_usage_bytes / longhorn_disk_capacity_bytes` cut-off in all
circumstances. Storage reservations, thin provisioning, the replica's requested
size, and scheduled bytes can all make a disk unschedulable earlier. The
percentage alerts give early warning; the `Schedulable` condition is
authoritative. Confirm live settings:

```bash
kubectl -n longhorn-system get settings.longhorn.io/storage-minimal-available-percentage -o yaml
kubectl -n longhorn-system get settings.longhorn.io/storage-over-provisioning-percentage -o yaml
kubectl -n longhorn-system get nodes.longhorn.io -o wide
```

## Grafana alerts routed to Discord

Grafana file-provisions these under **Alerting / Homelab / longhorn-storage**.
They use the existing `discord-primary` contact point and Vault webhook
rather than the unconfigured KPS Alertmanager.

| Rule | Firing condition | Pending |
| --- | --- | --- |
| LonghornDiskUsageWarning | Physical disk usage >65% | 10m |
| LonghornDiskUsageCritical | Physical disk usage >72% | 2m |
| LonghornDiskUnschedulable | Longhorn disk Schedulable=0 | 2m |
| LonghornDiskNotReady | Longhorn disk Ready=0 | 2m |
| LonghornNodeNotReady | Longhorn node Ready=0 | 2m |
| LonghornNodeSchedulingBlocked | Schedulable or AllowScheduling=0 | 2m |
| LonghornSchedulableNodesLow | Fewer than 3 eligible nodes | 3m |
| LonghornVolumeDegraded | Volume robustness degraded=1 | 2m |
| LonghornVolumeFaulted | Volume robustness faulted=1 | 1m |
| LonghornManagerScrapeFailed | Any manager target up=0 | 5m |
| LonghornManagerTargetsMissing | Fewer than 3 manager endpoints | 5m |

The expected three-node baseline is explicit because
`infra/nodes/labels/longhorn-workers.yaml` labels worker01/02/03 as storage nodes.
Update this baseline with any planned pool expansion or contraction.

## Rollout and verification

After merging the PR:

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization longhorn -n flux-system --with-source
flux reconcile kustomization observability -n flux-system --with-source
kubectl -n longhorn-system get networkpolicy allow-observability-prometheus-longhorn-metrics
kubectl -n observability rollout status deploy/prometheus
kubectl -n observability rollout status deploy/grafana
```

In Grafana Explore (datasource `prometheus`), verify:

```promql
up{job="longhorn-manager"}
```

```promql
longhorn_node_status{job="longhorn-manager",condition=~"ready|schedulable|allowScheduling"}
```

```promql
longhorn_disk_status{job="longhorn-manager",condition="schedulable"}
```

```promql
100 * longhorn_disk_usage_bytes{job="longhorn-manager"} / longhorn_disk_capacity_bytes{job="longhorn-manager"}
```

Check that the three manager endpoints return `up=1` and all three
storage nodes are present, then check Longhorn dashboard conditions. If
Grafana returns empty results, inspect the discovery targets in the
**standalone observability Prometheus** and verify TCP/9500 is permitted.

```bash
kubectl -n longhorn-system get endpoints longhorn-backend
kubectl -n longhorn-system get pods -l app=longhorn-manager -o wide
kubectl -n longhorn-system get nodes.longhorn.io -o json | jq -r '
  .items[] | .metadata.name as $node |
  (.status.diskStatus // {} | to_entries[] |
   [$node, .key, ((.value.conditions // []) |
    map(select(.type == "Schedulable")) |
    map(.status + ": " + (.message // "")) | join("; "))] | @tsv)'
```

The real root cause may be `StorageScheduled`, `StorageReserved`,
node/disk `allowScheduling`, disk pressure, or an unhealthy disk. No
disk configuration, replica count, scheduling permission, or PVC size is
modified by this PR.

Finally, use Grafana's **Contact points → discord-primary → Test** and
a controlled rule lifecycle to verify both firing and resolved
notifications. GitHub CI validates manifests and synthetic PromQL behavior,
not live reachability or Discord delivery. Provisioned alert files are
mounted via `subPath`, so an explicit Grafana rollout restart may be
required when editing alert-only files without another pod-template change.
