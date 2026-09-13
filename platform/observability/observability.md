# Observability Stack Homelab wiki

## Documentation
- Grafana: https://grafana.com/docs/grafana/latest/
- Loki: https://grafana.com/docs/loki/latest/
- Prometheus: https://prometheus.io/docs/
- Promtail: https://grafana.com/docs/loki/latest/send-data/promtail/

## Repo
https://github.com/grafana/grafana

## Releases
https://hub.docker.com/r/grafana/grafana

## Latest version
Grafana 13.0.1

## Objective
As home-admin I want a full observability stack (metrics, logs, dashboards, alerting) to monitor cluster health, detect issues, and receive alerts via Discord.

## Implementation
Grafana, Prometheus, Loki, and Promtail deployed as individual Kubernetes Deployments/StatefulSets. Grafana is provisioned with dashboards and alerting rules via ConfigMaps.

## Stack
Kubernetes Deployments/StatefulSets (Kustomize via Flux)

## LLD
- Namespace: observability
- Grafana: grafana/grafana:13.0.1, port tcp/3000
- Loki: log aggregation (StatefulSet)
- Prometheus: metrics collection
- Promtail: log shipping agent
- Dashboards: Golden Signals, Vault, Kubernetes Nodes, Platform, USE/RED methods
- Alerting: Discord webhook, time-sync rules
- Dependencies: ExternalSecret (Vault) for admin password and Discord webhook
