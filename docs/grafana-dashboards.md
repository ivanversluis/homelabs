# Grafana dashboard catalogue

Start with **Homelab Overview** (`homelab-overview`), the provisioned home page.
It links to five folders. Dashboard navigation keeps the selected time range;
shared variables such as the Firewall Manager environment namespace are carried
between related dashboards.

| Folder | Entry point | Drill-downs |
| --- | --- | --- |
| Kubernetes | Kubernetes Platform Overview | Workloads, Node Health, Node Resource Capacity, Time Sync |
| DNS | DNS Overview | CoreDNS, Pi-hole visibility and client drill-down, Unbound |
| Home | Home Climate / DSMR Smart Meter & Solar | GoodWe inverter detail in Home Energy, Shelly sensors |
| Firewall Manager | Firewall Manager - Overview | Golden Signals, RED service signals, USE resource signals |
| Platform Services | Prometheus Storage & Scrapers | HashiCorp Vault |

## Source and provisioning

Editable definitions are ordinary JSON under
`platform/observability/grafana/dashboards/`, organized in the same five domains.
The top-level `homelab-overview.json` provides the home page. There is one JSON
document per file. Edit these files and open a PR; managed dashboards are read-only
in Grafana, so UI edits cannot silently diverge from Git.

`platform/observability/kustomization.yaml` generates one ConfigMap per dashboard.
The existing logical ConfigMap names, dashboard UIDs and alert-linked panel IDs are
preserved. Content hashes are enabled, and Kustomize rewrites the Deployment's
projected ConfigMap references. A dashboard edit therefore updates the Grafana pod
template and triggers a rollout. Five folder projections replace individual
dashboard `subPath` mounts, which previously required manual restarts to update.
The root home-page JSON uses a single hashed `subPath` mount; its changes also
trigger a rollout.

Grafana's file provider reads `/var/lib/grafana/dashboards` with
`foldersFromFilesStructure: true`. Each folder is mounted separately with
file-level symlinks. A single projection with nested folder symlinks does not work
with Grafana's folder traversal; the smoke test reproduces Kubernetes's actual
AtomicWriter symlink layout. Mount paths use readable folder names;
the provider YAML itself stays under `/etc/grafana/provisioning/dashboards`.
These are different directories: provider YAML must not be scanned as dashboard
JSON. All resources remain in the existing observability Flux ownership boundary.
The Grafana PVC, security settings, secrets and alert rules are unchanged.

When adding a dashboard, add its JSON file, a ConfigMap generator and a projection
item. Use an explicit `{"type": "prometheus", "uid": "prometheus"}` datasource,
unique panel IDs and target `refId`s. Add navigation to its domain and the home page.
Use instant queries for current values and range queries for history. Keep missing
telemetry visible; do not make an unavailable target look healthy with invented
zero values. Preserve the UID and any panel ID referenced by an alert.

## Metrics contracts and repaired issues

Grafana uses the standalone `observability` Prometheus (`http://prometheus:9090`,
UID `prometheus`). It does not automatically use the separate Prometheus Operator
server in `monitoring`, and its static scrape configuration does not consume
ServiceMonitors.

- **Kubernetes Workloads** uses kube-state-metrics for scheduling state, requests
  and restarts, and cAdvisor for observed container usage and pod traffic.
  The new `kubernetes-cadvisor` scrape job uses verified HTTPS to the Kubernetes
  API server and the existing ServiceAccount token and `nodes/proxy` permission.
  It keeps only the four needed metric families. CPU/memory exclude empty and
  `POD` containers; pod network traffic deliberately includes the infra container.
  Namespace and pod selectors use metrics actually collected here.
- **Platform CPU** compares used host cores with total logical cores. Allocatable
  CPU is a Kubernetes scheduling budget and was an inconsistent denominator for
  host-wide usage. Node detail queries restrict the `node-exporter` job and label
  results by node, rather than exposing only IP addresses.
- **Home Climate** converts Unix seconds to milliseconds for Grafana's date units.
  It compares actual room temperatures with setpoints, shows operating mode/fan
  codes as states, and provides a room filter and API-poll age. `0` fan setting
  means a nonnumeric/automatic setting, not proof that the fan is off. Missing fan
  series remain missing and require exporter/device investigation.
- **Daikin collection** reads cached exporter metrics every 30 seconds. The prior
  ten-minute scrape interval exceeded Prometheus's five-minute default lookback,
  causing alternating instant-query gaps. The exporter still polls Onecta every
  600 seconds; this does not increase vendor API requests. Temperature lines use
  step interpolation, appropriate for these sampled readings.
- **Home Energy** contained two concatenated dashboard documents. Only the newer,
  complete definition is retained, with its existing UID.
- **Solar balance** aggregates single-site GoodWe and DSMR totals before
  subtraction: their `instance`/`job` labels differ, so direct subtraction returned
  an empty vector. Self-consumption is bounded to 0–100%, with no ratio at zero PV
  production. Multiple sites would require an explicit shared site label.
- **Pi-hole** uses the exporter's native `pihole_request_rate` gauge for queries/s.
  Daily and top-client reporting-window gauges are not monotonic counters. Client
  history displays reported counts, and a five-minute delta is labeled as a count
  change, including possible negative changes, rather than new queries.
- **Firewall Manager** shares an environment-namespace selector across all four
  dashboards to avoid mixing development, staging and production signals.
- **Prometheus storage** distinguishes scrape target counts, last-scrape samples,
  concurrent scrape durations and total active series. Its 50 GB comparison uses
  the configured decimal retention budget; it is not PVC/filesystem utilization
  or per-job disk accounting. Vault's mean latency uses a recent rate window.

Exporter contracts were checked against their source repositories:
Daikin `a9ca3ec48ce86426445f5ca0ca232cff8cf80678`, GoodWe
`cb88e74127e534a7a1779ae89942048bbe8643aa`, and Pi-hole exporter `v1.2.0`.
The deployed Daikin/GoodWe images use mutable `main` tags; these source checks do
not establish the exact binary currently running in the homelab.

## Imported and UI-created dashboards

The screenshots' **Cluster Monitoring for Kubernetes**, **K8S Dashboard** and
**Home Climate - ClickOps** are absent from the repository. Their complete JSON
and live errors cannot be reviewed here. A PR can provide the managed replacements
and fixes above, but cannot safely edit or remove unknown dashboards in Grafana's
database. Other root-level Grafana/Prometheus dashboards in the screenshot are
also outside the managed catalogue.

After deployment, compare the managed Platform Overview and Workloads dashboards
with the two imported Kubernetes dashboards, and managed Home Climate with the
ClickOps copy. Export any UI-only changes you want to keep before archiving or
deleting redundant copies. Preserve any valuable imported panels by submitting
their JSON through a later PR. Do not delete the `Homelab` folder automatically:
it can contain unmanaged dashboards and provisioned alert rules. Node-resource
and time-sync alert groups keep their existing alert folder and IDs.

## Validation and rollout

Local checks:

```bash
python3 scripts/test-grafana-dashboards.py
python3 scripts/test-node-resource-alerting.py
python3 scripts/test-grafana-provisioning.py  # Docker required
bash scripts/validate-kustomizations.sh
```

The dashboard test checks every JSON document, datasource UID, panel/target ID,
navigation link, generated ConfigMap and projected mount. Promtool parses every
panel expression and tests representative metric fixtures, including timestamp
conversion, room/pod selection, cross-exporter solar arithmetic, nighttime and
missing telemetry. The Docker smoke test loads the rendered definitions in the
repository's configured Grafana image, checks all dashboard/folder API responses,
and verifies the home page. It has no network connectivity, published ports or
homelab credentials, and always removes its own test container.

After merge and Flux reconciliation, the hashed dashboard references roll Grafana.
The existing generated Prometheus ConfigMap also changes its hash, rolling
Prometheus to load the new cAdvisor job and cached Daikin scrape interval. Check
both rollouts before evaluating dashboard data:

```bash
kubectl rollout status deployment/prometheus -n observability
kubectl rollout status deployment/grafana -n observability
```

Verify live Prometheus target health for `kube-state-metrics`, `node-exporter`,
`kubernetes-cadvisor` and `daikin-prometheus-exporter`. Compare cAdvisor's up-target
count with cluster nodes, then test CPU/memory data and namespace/pod selection in
Kubernetes Workloads. Check all five folders, preserved alert links, climate poll
age/date, and UI-only dashboards before retiring duplicates. Containerd must expose
the expected cAdvisor families; an absent family is a live collection problem,
not a reason to make a panel display fabricated zeroes. These live checks cannot
be claimed from an isolated development environment.
