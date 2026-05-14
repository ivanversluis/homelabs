# Headlamp Homelab wiki

## Documentation
https://headlamp.dev/docs/latest/

## Repo
https://github.com/headlamp-k8s/headlamp

## Releases
https://ghcr.io/headlamp-k8s/headlamp

## Latest version
latest

## Objective
As home-admin I want a modern Kubernetes web UI to visualize cluster resources, manage workloads, and monitor Flux GitOps reconciliation status.

## Implementation
Deployed as a Kubernetes Deployment with Flux plugin sidecar for GitOps visibility. OIDC authentication via Authentik.

## Stack
Kubernetes Deployment (Kustomize via Flux)

## LLD
- Namespace: headlamp
- Image: ghcr.io/headlamp-k8s/headlamp:latest
- Port: tcp/80 (Service) → container port 4466
- Plugins: Flux plugin (initContainer from ghcr.io/headlamp-k8s/headlamp-plugin-flux)
- Auth: Authentik OIDC
- RBAC: dedicated ServiceAccount, ClusterRole, ClusterRoleBinding
- Dependencies: ExternalSecret (Vault) for OIDC credentials
