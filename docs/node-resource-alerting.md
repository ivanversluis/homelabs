# Kubernetes node resource capacity and alerting

Issue: [#305](https://github.com/ivanversluis/homelabs/issues/305).

The **Homelab / Kubernetes Node Resource Capacity** dashboard (`k8s-node-resource-capacity`)
shows current CPU, memory and root filesystem utilization, 24-hour histories, and
available root space in GiB. Legends include the exporter-provided node label and
instance. The existing Kubernetes Node Health and time-sync resources remain provisioned.

| Rule | Condition | Pending period | Evaluation |
| --- | --- | --- | --- |
| NodeRootDiskUsageHigh | Root disk >70% | 4h | 1m |
| NodeMemoryUsageHigh | Memory >85% | 4h | 1m |
| NodeCPUUsageHigh | CPU >90% | 30m | 1m |

All rules have severity `warning`. CPU measures the five-minute average across
cores. Memory uses MemAvailable, so reclaimable cache is not counted as pressure.
Root disk uses filesystem available bytes, which reflects reserved-space impact.
Queries select the standalone Prometheus `node-exporter` job and preserve
`instance` and `node`; each instance has its own timer. Grafana's reduce/threshold
expressions preserve series labels. Equality with the threshold is healthy;
recovery resets Pending. These are continuous breaches, not time-window averages
(except the CPU rate). Missing data uses `NoData` and evaluation errors use
`Alerting`, matching the existing time-sync rules. Such monitoring failures can
notify separately from resource breaches.

The existing policy groups by alert name and instance and routes to
`discord-primary`: initial group wait 30s, group interval 5m, repeat interval 4h.
Firing and resolved messages include severity, summary, duration/threshold context,
instance/node, and dashboard/panel/alert links. No extra contact point or secret is
created. The webhook remains `$GRAFANA_DISCORD_WEBHOOK_URL` from the existing
ExternalSecret. The deployment's public Grafana URL determines notification links.

## Deploy and verify

After merging the PR:

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization observability -n flux-system --with-source
kubectl rollout status deployment/grafana -n observability
kubectl logs -n observability deployment/grafana --since=10m | \
  rg -i 'provision|alert|error'
```

The added mounts change the pod template, so the initial deployment restarts
Grafana automatically. Subsequent edits to these static `subPath` ConfigMaps
require `kubectl rollout restart deployment/grafana -n observability` after Flux
has applied them. File-provisioned rules/contact points are managed in Git.

1. Open **Dashboards → Homelab → Kubernetes Node Resource Capacity**. Check all
   nodes appear and the three history panels show data. Confirm warning lines at
   90% CPU, 85% memory, and 70% root disk.
2. Open **Alerting → Alert rules → Homelab → node-resources**. Confirm the three
   rules, thresholds, pending periods, datasource `prometheus`, and separate
   instances. A node above 70% should be Pending until the four-hour period ends.
3. Update the webhook through the existing Vault/ExternalSecret path. Updating a
   Kubernetes secret does not refresh the running pod's environment; wait for
   secret synchronization and restart Grafana. Editing this provisioned contact
   point in the UI may be blocked or overwritten by file provisioning.
4. In **Contact points → discord-primary → Test**, send a test notification to
   check webhook connectivity. Then perform the controlled lifecycle test below
   to verify evaluation, routing and resolved delivery as well.

## Controlled end-to-end Discord test

Use a temporary **UI-created Grafana-managed rule**; do not change production
thresholds or fill a node's filesystem.

1. Create rule `NodeResourceNotificationTest` in folder `Homelab`, in a separate
   evaluation group `node-resource-test` with interval **10s**.
2. Query A: datasource **Prometheus**, query type **Instant**, expression
   `label_replace(vector(1), "instance", "notification-test", "", ".*")`.
3. Expression B: **Reduce**, input A, function **Last**. Expression C:
   **Threshold**, input B, **Is above 0**. Make C the alert condition.
4. Set Pending to **0s**, severity label `warning`, component `node-resources`.
   Summary: `Controlled node resource notification test`. Description:
   `Synthetic test: value >0 for 0s; no node resource pressure is generated`.
   Link the new dashboard's root-disk panel. Use the existing notification policy
   (no receiver override and no mute timing).
5. Save, confirm **Firing**, then allow the policy's 30s group wait. Check Discord
   contains alert name, instance `notification-test`, severity, context and link.
6. Change A to
   `label_replace(vector(0), "instance", "notification-test", "", ".*")`.
   Keep the rule enabled. Confirm **Normal** and wait up to the policy's **5m**
   group interval for the resolved notification.
7. Delete the temporary rule after both messages arrive. Pausing or deleting it
   before recovery is evaluated does not test resolved delivery.

This proves the notification lifecycle; it does not shorten the real rules'
4h/30m pending periods. Production Pending starts at evaluation and can restart
after Grafana restarts. Do not mark live delivery verified until both test
messages are observed.

## Troubleshooting

- Empty panels/NoData: confirm the standalone Prometheus `node-exporter` targets
  and the existing node-health dashboard; Grafana uses the `observability`
  Prometheus, not the separate `monitoring` Prometheus instance.
- Firing without a message: inspect the rule's notification preview, silences,
  contact-point test result, Grafana logs, webhook secret synchronization and
  Grafana egress. An above-threshold Pending instance does not notify yet.
- Links point to an unexpected host: check the existing `GRAFANA_PUBLIC_URL`
  secret consumed by `GF_SERVER_ROOT_URL` and restart Grafana after changes.

References: [Grafana alerting file provisioning](https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/)
and [dashboard/panel alert links](https://grafana.com/docs/grafana/latest/alerting/alerting-rules/link-alert-rules-to-panels/).
