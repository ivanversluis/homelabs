# Workloads

This directory contains Kubernetes-consumed workloads that run on top of the homelab platform.

```text
workloads/
├── apps/    # application workloads
└── vms/     # KubeVirt VirtualMachine workloads
```

## Ownership rule

Moving content under `workloads/` must not change the Flux or Argo CD owner of a live Kubernetes object. Wave 2 preserves existing Flux `Kustomization` names, dependencies, prune settings, namespaces, and resource manifests; only repository source paths change.

A future ownership change is a separate migration and must use a staged prune-disable/adopt/verify procedure. Never combine ownership transfer with a folder rename.

Repository paths and Vault secret paths are separate contracts. Existing Vault keys such as `apps/<component>` remain unchanged unless an explicit secret migration is planned.
