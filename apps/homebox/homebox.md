# Homebox Homelab wiki

## Documentation
https://homebox.software/en/

## Repo
https://github.com/sysadminsmedia/homebox

## Releases
https://ghcr.io/sysadminsmedia/homebox

## Latest version
latest

## Objective
As home-admin I want a self-hosted home inventory management system to track and organize household items, their locations, and maintenance schedules.

## Implementation
Deployed as a Kubernetes Deployment with persistent storage and OIDC authentication via Authentik.

## Stack
Kubernetes Deployment (Kustomize via Flux)

## LLD
- Namespace: homebox
- Image: ghcr.io/sysadminsmedia/homebox:latest
- Port: tcp/7745
- Volume: PVC mounted at /data (Longhorn)
- Security: runAsUser 65532, runAsNonRoot
- Dependencies: ExternalSecret (Vault) for OIDC client credentials, Authentik as IdP
