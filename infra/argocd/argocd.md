# Argo CD Homelab wiki

## Documentation
https://argo-cd.readthedocs.io/en/stable/

## Repo
https://github.com/argoproj/argo-cd

## Releases
https://artifacthub.io/packages/helm/argo/argo-cd

## Latest version
Helm chart 9.5.13

## Objective
As home-admin I want a GitOps continuous delivery tool to declaratively manage application deployments and visualize sync status across the cluster.

## Implementation
Deployed via Flux HelmRelease. Provides ApplicationSet support and exec capabilities. Metrics enabled for Prometheus scraping.

## Stack
Helm (FluxCD HelmRelease)

## LLD
- Namespace: argocd
- Helm chart: argo-cd v9.5.13
- Service: ClusterIP
- Features: exec enabled, ApplicationSet enabled
- Metrics: server, controller, repoServer
- CRDs: installed
- Dependencies: ExternalSecret (Vault) for repo credentials
