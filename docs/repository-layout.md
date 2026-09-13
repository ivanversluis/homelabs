# Repository layout and ownership model

## Purpose

The repository is organized by architectural responsibility. The folder name should tell an operator what role a component has in the homelab before they inspect how it is installed.

The primary rule is:

> **`platform/` makes Kubernetes work. `infra/`, `services/`, and `workloads/` run on or consume the platform.**

## Top-level areas

| Area | Responsibility | Examples |
|---|---|---|
| `clusters/` | Cluster-specific reconciliation wiring and boundaries | `clusters/k8s-homelab/platform/`, `clusters/k8s-homelab/workloads/` |
| `platform/` | Kubernetes system capabilities and cluster-wide controllers | Calico, MetalLB, Longhorn, CoreDNS, KubeVirt, CDI, cert-manager, External Secrets, observability |
| `infra/` | Shared infrastructure and management software running on Kubernetes | Vault, Kong, Headlamp, Portainer, SemaphoreUI, OpenClaw, AI tooling |
| `services/` | Shared runtime services consumed by clients/workloads | Authentik, Pi-hole, Unbound, Cloudflare Tunnel |
| `workloads/apps/` | Application workloads | n8n, Forgejo, Linkding, Termix, Firewall Manager |
| `workloads/vms/` | Virtual-machine workloads | KubeVirt `VirtualMachine` resources |
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

`platform/observability/monitoring/` contains the kube-prometheus-stack/metrics-server monitoring plane. The standalone Prometheus/Grafana/Loki/Promtail stack remains directly under `platform/observability/`. They are intentionally separate deployment units within one architectural capability area.

## Workload categories

```text
workloads/
├── apps/
└── vms/
```

`workloads/apps/` contains application workloads regardless of whether Flux or Argo CD reconciles them. `workloads/vms/` contains VM workload definitions; the KubeVirt/CDI runtime remains under `platform/virtualization/`.

## Classification test

Use these questions when adding or moving a component:

1. **Does Kubernetes depend on it for a cluster capability such as networking, storage, virtualization, observability, certificates, or secret delivery?** Put it in `platform/`.
2. **Is it a shared runtime service consumed by clients or workloads?** Put it in `services/`.
3. **Is it management, automation, gateway, secrets-backend, or other supporting infrastructure running on the platform?** Put it in `infra/`.
4. **Is it an application workload?** Put it in `workloads/apps/`.
5. **Is it a VM workload rather than the virtualization runtime itself?** Put it in `workloads/vms/`.

Installation mechanism is not a classification criterion. A HelmRelease, operator, controller, DaemonSet, or plain Deployment can all be platform components depending on their architectural role.

## GitOps ownership

The root cluster entrypoint is `clusters/k8s-homelab/kustomization.yaml`.

Platform components with special ordering, substitution, state, or safety requirements keep dedicated Flux `Kustomization` objects under `clusters/k8s-homelab/platform/`.

Wave 2 keeps workload reconciliation identities stable under `clusters/k8s-homelab/workloads/`. Existing Flux `Kustomization` names, namespaces, dependency chains, prune settings, substitution behavior, and live inventories stay the same; only repository source paths change. Firewall Manager remains owned by the existing Argo CD `ApplicationSet`, with only its source path updated.

### Ownership-transfer safety rule

A repository path move and a GitOps ownership transfer are different operations.

- A path-only Flux move keeps the same `Kustomization` object and changes only `spec.path` plus repository file locations.
- Moving live resources between Flux inventories requires a staged migration: protect or disable prune, reconcile, adopt with the new owner, verify live inventory/labels, remove from the old owner, then restore pruning.
- Namespace, CRD, PVC, StorageClass, operator CR, and stateful ownership changes are destructive-risk changes and require an explicit migration plan.
- Any P1 review finding involving prune, inventory, namespace deletion, ownership, or persistence is a merge blocker.

This means folder restructuring must not collapse or transfer reconciliation boundaries merely to simplify the tree.

## Secret-path rule

Repository paths and Vault paths are separate contracts. Existing Vault keys such as `apps/<component>` or `infra/observability` are **not renamed automatically** when manifests move. A Vault key is changed only as a deliberate secret migration with both producer and consumer updated together.

## Restructuring waves

### Wave 1 - platform components

Completed: Kubernetes system capabilities moved into `platform/` with their reconciliation boundaries preserved.

### Wave 2 - workloads

Application and VM workload sources move into `workloads/apps/` and `workloads/vms/`. Reconciliation owners remain unchanged. The validation and merge gate are documented in `docs/lifecycle/wave2-workloads.md`.
