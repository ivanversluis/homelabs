# Linkding Homelab wiki

## Documentation
https://github.com/sissbruecker/linkding/blob/master/docs/README.md

## Repo
https://github.com/sissbruecker/linkding

## Releases
https://hub.docker.com/r/sissbruecker/linkding

## Current version
1.47.0-alpine

## Objective
As home-admin I want a self-hosted bookmark manager to save, tag, and search web links without relying on browser sync or third-party services.

## Implementation
Deployed as a Kubernetes Deployment with persistent storage for the SQLite database and OIDC enabled via Authentik.

## Stack
Kubernetes Deployment (Kustomize via Flux)

## LLD
- Namespace: linkding
- Image: `sissbruecker/linkding:1.47.0-alpine`
- Image policy: `IfNotPresent`; the workload is version-pinned so pod rescheduling does not trigger implicit upgrades
- Port: tcp/9090
- Volume: linkding-pvc mounted at /etc/linkding/data
- Security: default non-privileged container runtime settings
- Dependencies: ExternalSecret (`linkding-oidc`) for OIDC client credentials, Kong for Authentik OIDC endpoints, PVC-backed SQLite storage
