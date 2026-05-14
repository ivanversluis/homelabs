# Monitoring (kube-prometheus-stack) Homelab wiki

## Documentation
https://prometheus-operator.dev/docs/

## Repo
https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

## Releases
https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack

## Latest version
Helm chart 84.x

## Objective
As home-admin I want Prometheus Operator and kube-state-metrics to collect Kubernetes metrics, provide alerting rules, and expose ServiceMonitor CRDs for all workloads.

## Implementation
Deployed via Flux HelmRelease. Grafana is disabled (managed separately in observability stack). Prometheus Operator runs on master node with control-plane toleration.

## Stack
Helm (FluxCD HelmRelease)

## LLD
- Namespace: monitoring
- Helm chart: kube-prometheus-stack v84.x
- Components: Prometheus Operator, kube-state-metrics, metrics-server
- Grafana: disabled (external)
- Node placement: Operator on k8s-master01 (control-plane toleration)
- Dependencies: None (foundational monitoring)
