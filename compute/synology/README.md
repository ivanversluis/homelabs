# Synology

This tree contains Synology-specific desired state and container-service definitions that are separate from the Kubernetes homelab cluster.

## Current scope

```text
compute/synology/
└── workloads/
    └── apps/
        └── portainer/
```

`workloads/apps/portainer/` contains the existing Synology Container Manager / Docker Compose definition. It is retained here while the remaining Synology-hosted services and their future operating model are reviewed.

## Important boundary

This directory is not part of `compute/eliteboxes/` and must not be added to the Kubernetes Flux root implicitly.

A future Synology GitOps/deployment mechanism must be designed explicitly. Until then, files here are source-controlled desired-state/reference definitions only and Wave 3 does not deploy, stop, or modify services running on the Synology NAS.

## Future Flux and Semaphore onboarding

If a Kubernetes cluster is later hosted on a Synology VM or another supported host, add a reviewed Synology-specific Kubernetes entrypoint before bootstrapping Flux with `--path=compute/synology`. Select its platform components and storage/network configuration explicitly; keep the native DSM/Compose deployment boundary separate.

Add Synology host inventory, pinned host keys, narrowly scoped Vault/SSH/network access, and environment-specific Semaphore maintenance templates before scheduling jobs. Native DSM maintenance needs its own tested procedure. Do not add the NAS to the existing Arch Linux/kubeadm maintenance target group automatically.

See [the compute migration and onboarding runbook](../../docs/lifecycle/compute-layout-migration.md).
