# cert-manager Homelab wiki

## Documentation
https://cert-manager.io/docs/

## Repo
https://github.com/cert-manager/cert-manager

## Releases
https://artifacthub.io/packages/helm/cert-manager/cert-manager

## Latest version
v1.17.x

## Objective
As home-admin I want automated TLS certificate issuance and renewal for all homelab services using Let's Encrypt and wildcard certificates.

## Implementation
Deployed via Flux HelmRelease with CRDs installed. Provides wildcard certificates consumed by Kong ingress for all *.DOMAIN services.

## Stack
Helm (FluxCD HelmRelease)

## LLD
- Namespace: cert-manager
- Helm chart: cert-manager v1.17.x
- CRDs: installed
- Prometheus metrics: enabled
- Dependencies: None (foundational service, consumed by Kong and other ingresses)
