# Repository layout and ownership model

## Purpose

The repository is organized by architectural responsibility. The folder name should tell an operator what role a component has in the homelab before they inspect how it is installed.

The primary rule is:

> **`platform/` makes Kubernetes work. `infra/` operates the homelab. `services/` provide shared runtime capabilities. `workloads/` are the use cases that consume them.**

## Top-level areas

| Area | Responsibility | Examples |
|---|---|---|
| `clusters/` | Environment-specific desired state, reconciliation wiring, and boundaries | `clusters/k8s-homelab/`, `clusters/synology/` |
| `platform/` | Kubernetes system capabilities and cluster-wide controllers | Calico, MetalLB, Longhorn, CoreDNS, KubeVirt, CDI, cert-manager, External Secrets, observability |
| `infra/` | Homelab operations and management control plane | Vault, Argo CD, Headlamp, Portainer, SemaphoreUI, OpenClaw |
| `services/` | Shared runtime/data-plane services consumed by clients, workloads, or platform components | Kong, Authentik, Pi-hole, Unbound, Cloudflare Tunnel, telemetry exporters |
| `workloads/apps/` | User/application use cases | AI/Open WebUI, n8n, Forgejo, Linkding, Termix, Firewall Manager |
| `workloads/vms/` | Virtual-machine workloads | KubeVirt `VirtualMachine` resources |
| `automation/` | Lifecycle and infrastructure automation | Ansible, Terraform |
| `scripts/` | Bootstrap, migration, validation, and operator helper scripts | KubeVirt bootstrap, storage-class migration, Zero Trust validation |
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

Wave 1 established `platform/` as the Kubernetes capability layer. Later waves should not move ordinary applications or shared business/runtime services into `platform/` simply because they use Helm, operators, CRDs, or cluster-wide permissions.

## Infrastructure categories

`infra/` contains software whose primary consumer is the operator or automation that manages the homelab rather than an application request path.

Canonical examples:

- `infra/argocd/` and `infra/argocd-image-updater/` - deployment/GitOps control plane;
- `infra/headlamp/` and `infra/portainer/` - Kubernetes management interfaces;
- `infra/semaphoreui/` - infrastructure automation interface;
- `infra/vault/` and `infra/vault-config/` - secrets-management backend and integration;
- `infra/flux-substitution/` - GitOps variable plumbing;
- `infra/nodes/` - node administration/configuration;
- `infra/openclaw/` - Kubernetes operations agent.

OpenClaw remains infrastructure even though it uses AI, because the deployed agent's purpose is Kubernetes operations, monitoring, and incident notification.

## Shared service categories

```text
services/
├── dns/
│   ├── pihole/
│   └── unbound/
├── gateway/
│   └── kong/
├── identity/
│   └── authentik/
├── telemetry/
│   └── home-exporters/
└── tunnel/
    └── cloudflare/
```

A shared service sits in a normal runtime/data path and is consumed by multiple clients or workloads. Kong is therefore a service rather than management infrastructure: it provides ingress, TLS, API/AI gateway functionality and policy enforcement to many other components. Home telemetry exporters are service adapters between physical/cloud devices and the observability platform.

## Workload categories

```text
workloads/
├── apps/
└── vms/
```

`workloads/apps/` contains application/use-case workloads regardless of whether Flux or Argo CD reconciles them. The AI stack belongs here because Open WebUI and its MCP components form a user-facing AI use case that consumes Kong, Authentik, Vault, and Kubernetes APIs.

`workloads/vms/` contains VM workload definitions; the KubeVirt/CDI runtime remains under `platform/virtualization/`.

## Cluster/environment categories

`clusters/k8s-homelab/` contains the Flux/Argo wiring for the Kubernetes cluster.

`clusters/synology/` contains Synology-specific desired state and container-service definitions. It is deliberately separate from the Kubernetes Flux root. Wave 3 places the legacy Synology Portainer Compose definition at `clusters/synology/workloads/apps/portainer/` while the remaining Synology service model is evaluated.

Nothing under `clusters/synology/` is automatically reconciled by Kubernetes Flux unless a future change explicitly designs and wires such a mechanism.

## Classification test

Use these questions in order when adding or moving a component:

1. **Does Kubernetes itself depend on it for a cluster capability such as networking, storage, virtualization, observability, certificates, or secret delivery?** Put it in `platform/`.
2. **Is its primary purpose operating/managing the homelab, GitOps, infrastructure automation, node administration, or the secrets-management control plane?** Put it in `infra/`.
3. **Is it a shared runtime/data-plane capability consumed by multiple clients, workloads, or platform components?** Put it in `services/`.
4. **Is it a user/application use case that consumes those shared capabilities?** Put it in `workloads/apps/`.
5. **Is it a VM workload rather than the virtualization runtime itself?** Put it in `workloads/vms/`.
6. **Is it environment-specific desired state outside the Kubernetes cluster, such as Synology Container Manager configuration?** Put it under the matching `clusters/<environment>/` tree.

Installation mechanism is not a classification criterion. A HelmRelease, operator, controller, DaemonSet, Deployment, or CRD can belong to any category depending on architectural role.

## GitOps ownership

The Kubernetes root cluster entrypoint is `clusters/k8s-homelab/kustomization.yaml`.

Components with special ordering, substitution, state, or safety requirements keep dedicated Flux `Kustomization` objects in the matching cluster category.

Wave 2 kept workload reconciliation identities stable while moving application and VM sources.

Wave 3 keeps these Flux identities stable while reclassifying their source locations:

```text
kong             -> ./services/gateway/kong
home-exporters   -> ./services/telemetry/home-exporters
identity-ingress -> ./services/identity/kong-ingress
ai               -> ./workloads/apps/ai
```

Only the source paths/file organization change. The live reconciliation owner remains the same Flux Kustomization object.

### Ownership-transfer safety rule

A repository path move and a GitOps ownership transfer are different operations.

- A path-only Flux move keeps the same `Kustomization` object and changes only `spec.path` plus repository file locations.
- Moving live resources between Flux inventories requires a staged migration: protect or disable prune, reconcile, adopt with the new owner, verify live inventory/labels, remove from the old owner, then restore pruning.
- Namespace, CRD, PVC, StorageClass, operator CR, and stateful ownership changes are destructive-risk changes and require an explicit migration plan.
- Any P1/P2 finding involving prune, inventory, namespace deletion, ownership, persistence, or unintended recreation is a merge blocker.

Folder restructuring must not collapse or transfer reconciliation boundaries merely to simplify the tree.

## Secret-path rule

Repository paths and Vault paths are separate contracts. Existing Vault keys such as `apps/<component>`, `infra/kong`, `infra/home-exporters/...`, or `infra/observability` are **not renamed automatically** when manifests move. A Vault key is changed only as a deliberate secret migration with both producer and consumer updated together.

## Restructuring waves

### Wave 1 - platform components

Completed: Kubernetes system capabilities moved into `platform/` with their reconciliation boundaries preserved.

### Wave 2 - workloads

Completed: application and VM workload sources moved into `workloads/apps/` and `workloads/vms/` while preserving existing GitOps owners. Validation is documented in `docs/lifecycle/wave2-workloads.md`.

### Wave 3 - responsibility classification

Kong moves to shared services, home exporters move to telemetry services, the AI stack moves to application workloads, cluster reconciliation files are filed with their matching categories, and the legacy Synology Portainer definition moves under `clusters/synology/`. Existing Kubernetes Flux ownership remains unchanged. Validation is documented in `docs/lifecycle/wave3-classification.md`.
