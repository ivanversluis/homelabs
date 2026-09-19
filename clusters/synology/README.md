# Synology

This tree contains Synology-specific desired state and container-service definitions that are separate from the Kubernetes homelab cluster.

## Current scope

```text
clusters/synology/
└── workloads/
    └── apps/
        └── portainer/
```

`workloads/apps/portainer/` contains the existing Synology Container Manager / Docker Compose definition. It is retained here while the remaining Synology-hosted services and their future operating model are reviewed.

## Important boundary

This directory is not part of `clusters/k8s-homelab/` and must not be added to the Kubernetes Flux root implicitly.

A future Synology GitOps/deployment mechanism must be designed explicitly. Until then, files here are source-controlled desired-state/reference definitions only and Wave 3 does not deploy, stop, or modify services running on the Synology NAS.
