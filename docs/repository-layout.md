# Repository layout and ownership model

## Purpose

The repository is organized by architectural responsibility. The folder name should tell an operator what role a component has in the homelab before they inspect how it is installed.

The primary rule is:

> **`platform/` makes Kubernetes work. `services/`, `apps/`, and `vms/` consume the platform.**

## Top-level areas

| Area | Responsibility | Examples |
|---|---|---|
| `clusters/` | Cluster-specific Flux wiring and reconciliation boundaries | `clusters/k8s-homelab/platform/` |
| `platform/` | Kubernetes system capabilities and cluster-wide controllers | Calico, MetalLB, Longhorn, CoreDNS, KubeVirt, CDI, cert-manager, External Secrets, observability |
| `infra/` | Shared infrastructure and management software running on Kubernetes | Vault, Kong, Headlamp, Portainer, SemaphoreUI, OpenClaw, AI tooling |
| `services/` | Shared runtime services consumed by clients/workloads | Authentik, Pi-hole, Unbound, Cloudflare Tunnel |
| `apps/` | Application workloads | n8n, Forgejo, Linkding, Termix |
| `vms/` | Virtual-machine workloads | KubeVirt `VirtualMachine` resources |
| `automation/` | Lifecycle and infrastructure automation | Ansible, Terraform |
| `scripts/` | Bootstrap, validation, and operator helper scripts | KubeVirt bootstrap, Zero Trust validation |
| `docs/` | Architecture and operating knowledge | DNS, observability, lifecycle waves |

## Platform categories

```text
platform/
├── networking/
│   ├── calico/
│   ├── coredns/
│   ├── metallb/
│   └── network-policies/
├── storage/
│   ├── longhorn/
│   └── local-path-provisioner/
├── virtualization/
│   ├── kubevirt/
│   └── cdi/
├── observability/
│   ├── prometheus/
│   ├── grafana/
│   ├── loki/
│   ├── promtail/
│   └── monitoring/
└── security/
    ├── cert-manager/
    └── external-secrets/
```

`platform/observability/monitoring/` contains the kube-prometheus-stack/metrics-server monitoring plane. The existing standalone Prometheus/Grafana/Loki/Promtail stack remains directly under `platform/observability/`. They are intentionally kept as two deployment units while sharing one architectural capability area.

## Classification test

Use these questions when adding or moving a component:

1. **Does Kubernetes depend on it for a cluster capability such as networking, storage, virtualization, observability, certificates, or secret delivery?** Put it in `platform/`.
2. **Is it a shared runtime service consumed by clients or workloads?** Put it in `services/`.
3. **Is it management, automation, gateway, secrets-backend, or other supporting infrastructure running on the platform?** Put it in `infra/`.
4. **Is it an application workload?** Put it in `apps/`.
5. **Is it a VM workload rather than the virtualization runtime itself?** Put it in `vms/`.

Installation mechanism is not a classification criterion. A HelmRelease, operator, controller, DaemonSet, or plain Deployment can all be platform components depending on their architectural role.

## GitOps ownership

The root cluster entrypoint is `clusters/k8s-homelab/kustomization.yaml`.

Platform components with special ordering, substitution, state, or safety requirements keep dedicated Flux `Kustomization` objects under `clusters/k8s-homelab/platform/`. Examples include Calico CRDs before Calico, cert-manager before its ClusterIssuers, KubeVirt before CDI, and monitoring Kong consumers after their generated Secret exists.

This means folder restructuring must not collapse those reconciliation boundaries merely to simplify the tree.

## Secret-path rule

Repository paths and Vault paths are separate contracts. Existing Vault keys such as `infra/observability` or `infra/cert-manager` are **not renamed automatically** when a manifest moves into `platform/`. A Vault key is changed only as a deliberate secret migration with both producer and consumer updated together.

## Restructuring waves

### Wave 1 - platform components

Move Kubernetes system capabilities into `platform/` and align Flux paths, scripts, and documentation. Workload locations remain stable.

### Wave 2 - workloads

A later change can evaluate whether `apps/` and `vms/` should be grouped under a common `workloads/` parent. That change is explicitly outside Wave 1 so platform refactoring and workload ownership changes are not mixed in one migration.
