# External Secrets Operator Homelab wiki

## Documentation
https://external-secrets.io/latest/

## Repo
https://github.com/external-secrets/external-secrets

## Releases
https://artifacthub.io/packages/helm/external-secrets/external-secrets

## Latest version
2.4.0

## Objective
As home-admin I want to sync secrets from HashiCorp Vault into Kubernetes Secrets automatically, eliminating manual secret management and enabling GitOps for all workloads.

## Implementation
Deployed via Flux HelmRelease with CRDs, webhook, and cert controller. ExternalSecret CRs in each namespace reference a ClusterSecretStore backed by Vault.

## Stack
Helm (FluxCD HelmRelease)

## LLD
- Namespace: external-secrets-system
- Helm chart: external-secrets v2.4.0
- Components: Operator, Webhook, CertController
- ServiceAccount: external-secrets-operator
- CRDs: installed
- Dependencies: Vault (backend secret store)
