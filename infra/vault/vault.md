# HashiCorp Vault Homelab wiki

## Documentation
https://developer.hashicorp.com/vault/docs

## Repo
https://github.com/hashicorp/vault

## Releases
https://artifacthub.io/packages/helm/hashicorp/vault

## Latest version
Helm chart 0.32.0

## Objective
As home-admin I want a centralized secrets management solution to store and inject secrets into all homelab workloads via the External Secrets Operator.

## Implementation
Deployed via Flux HelmRelease in standalone mode with file-based storage. Starts sealed — manual unseal required after pod restart.

## Stack
Helm (FluxCD HelmRelease)

## LLD
- Namespace: vault
- Helm chart: vault v0.32.0
- Port: tcp/8200 (ClusterIP)
- Storage: file backend at /vault/data (PVC)
- UI: enabled
- Telemetry: Prometheus metrics (12h retention)
- Dependencies: None (foundational service)
