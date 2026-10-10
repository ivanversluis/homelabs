# Observability Architecture

This page documents the metrics, logs, dashboards, and DNS visibility implementation.

## Platform location

Observability is a Kubernetes platform capability and is stored under:

```text
platform/observability/
├── prometheus/           # standalone Prometheus and static scrape config
├── grafana/              # dashboards, datasource, OIDC configuration
├── loki/                 # log aggregation
├── promtail/             # node log shipping
├── dns/                  # ServiceMonitors for DNS components
├── vault/                # ExternalSecret consumers for observability secrets
└── monitoring/           # kube-prometheus-stack, metrics-server, Gatus, MikroTik proxy
```

The two Prometheus planes are intentionally distinct:

- `observability` namespace: a **plain Prometheus** deployment using `scrape_configs` from `platform/observability/prometheus/prometheus.yml`.
- `monitoring` namespace: kube-prometheus-stack/Prometheus Operator, which consumes `ServiceMonitor` CRDs.

Moving both deployment units below `platform/observability/` changes repository ownership only; it does not merge their runtime behavior.

## DNS observability

The DNS layer connects CoreDNS, Pi-hole, and Unbound exporters to Prometheus.

```mermaid
flowchart TD
  subgraph kube-system
    CD[CoreDNS :9153]
  end
  subgraph pihole
    PE[pihole-exporter :9617]
  end
  subgraph dns
    UB[Unbound]
    UB --> UE[unbound-exporter :9167]
  end
  subgraph observability
    CM[prometheus-config\nstatic_configs]
    P[Prometheus]
    G[Grafana]
    CM --> P
  end
  CD --> P
  PE --> P
  UE --> P
  P --> G
```

### CoreDNS

- Metrics Service: `platform/networking/coredns/coredns-metrics-service.yaml`
- ServiceMonitor: `platform/observability/dns/coredns-servicemonitor.yaml`
- Static target: `coredns-metrics.kube-system.svc.cluster.local:9153`

### Pi-hole

- Exporter deployment/service remain with the shared service under `services/dns/pihole/k8s/`.
- ServiceMonitor: `platform/observability/dns/pihole-servicemonitor.yaml`
- Static target: `pihole-exporter.pihole.svc.cluster.local:9617`

### Unbound

- Exporter remains a sidecar in `services/dns/unbound/k8s/unbound-deployment.yaml`.
- The sidecar uses `unix:///var/run/unbound/unbound.ctl` and runs as uid 1000 to match the Unbound control socket ownership.
- ServiceMonitor: `platform/observability/dns/unbound-servicemonitor.yaml`
- Static target: `unbound-exporter.dns.svc.cluster.local:9167`

## Standalone Prometheus

Static scrape jobs are defined in:

```text
platform/observability/prometheus/prometheus.yml
```

`ServiceMonitor` resources do not configure this Prometheus instance. They are consumed by the separate kube-prometheus-stack instance under `platform/observability/monitoring/`.

Kustomize generates a hashed ConfigMap from this file; changes roll Prometheus
automatically. Verify the updated deployment after Flux reconciliation:

```bash
kubectl rollout status deployment/prometheus -n observability
```

## Dashboards and alerting

The [dashboard catalogue](grafana-dashboards.md) describes folder navigation,
metrics contracts, imported-dashboard migration and local/live validation.
Dashboard JSON lives under `platform/observability/grafana/dashboards/`; Kustomize
generates ConfigMaps and Grafana projects them into five domain folders.

DNS dashboards include:

- DNS Overview
- CoreDNS Health
- Pi-hole Client Visibility
- Unbound Recursive Resolver

Prometheus alert rules are stored in `platform/observability/prometheus/prometheus-alerts.yml` and cover CoreDNS error/latency conditions plus Pi-hole and Unbound exporter/upstream failures. Grafana's provisioned alert rules remain under `platform/observability/grafana/`.

## Network-policy requirements

The observability data plane depends on explicit policy allows:

- `observability` -> `pihole` TCP/9617;
- `observability` -> `dns` TCP/9167;
- `observability` -> `kube-system` TCP/9153;
- required egress from the monitoring/observability components according to their manifests.

The cluster-wide policy baseline is in `platform/networking/network-policies/`.

## Flux reconciliation

The standalone observability stack is reconciled through:

```text
compute/eliteboxes/platform/observability-kustomization.yaml
```

The kube-prometheus-stack monitoring plane is reconciled through:

```text
compute/eliteboxes/platform/monitoring-kustomization.yaml
```

The RouterOS integration, including its Gatus KongConsumer, lives under `services/gateway/kong/api-gateway/routeros-upstream/`. Its bootstrap Flux reconciliation waits for the ExternalSecret-generated credentials before the route, plugins, and consumer are applied.

## Operational rule

When adding a platform-wide telemetry capability, place its manifests under `platform/observability/`. Exporters that are tightly coupled to a service remain with that service; their scrape/discovery configuration belongs to the observability platform.
