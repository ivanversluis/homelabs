# Kubernetes platform

This directory contains Kubernetes system and platform capabilities that workloads depend on.

> **Rule:** `platform/` makes Kubernetes work. `services/`, `apps/`, and `vms/` consume the platform.

## Structure

- `networking/` — CNI, cluster DNS, LoadBalancer implementation, and network policy baseline.
- `storage/` — CSI/persistent storage and node-local provisioning capabilities.
- `virtualization/` — KubeVirt and CDI platform controllers.
- `observability/` — metrics, logs, dashboards, alerting, and cluster monitoring components.
- `security/` — cluster-wide security controllers such as cert-manager and External Secrets.

## GitOps model

Critical or stateful platform components keep their existing dedicated Flux `Kustomization` boundaries under `clusters/k8s-homelab/platform/`. This refactor changes repository ownership and paths, not the intended reconciliation or persistence behavior.

Application and VM workload restructuring is deliberately out of scope for this wave.
