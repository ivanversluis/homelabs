# Compute environments

This area contains environment-specific desired state and GitOps reconciliation wiring. Shared Kubernetes definitions stay in `platform/`, `infra/`, `services/`, and `workloads/`.

| Directory | Current state | Deployment boundary |
|---|---|---|
| `eliteboxes/` | Existing four-node HP EliteDesk Kubernetes cluster | Active Flux root at `./compute/eliteboxes` |
| `pi4/` | Reserved for the Raspberry Pi 4 Kubernetes rebuild | Documentation only; no active Flux entrypoint yet |
| `synology/` | Existing Synology Container Manager definitions | Compose/reference content; no active Kubernetes Flux entrypoint yet |

There is deliberately no shared `compute/kustomization.yaml`. Each Kubernetes cluster must reconcile its own environment directory. Do not point the EliteBox Flux root at `compute/` or include Pi4/Synology implicitly.

The existing cluster name, Flux object names, Ansible group `k8s_homelab`, and Vault paths remain unchanged. `eliteboxes` is the repository environment name.

See [the migration and onboarding runbook](../docs/lifecycle/compute-layout-migration.md) before merging or bootstrapping another environment.
