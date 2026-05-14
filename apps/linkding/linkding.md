# Linkding Homelab wiki

## Documentation
https://github.com/sissbruecker/linkding/blob/master/docs/README.md

## Repo
https://github.com/sissbruecker/linkding

## Releases
https://hub.docker.com/r/sissbruecker/linkding

## Latest version
latest

## Objective
As home-admin I want a self-hosted bookmark manager to save, tag, and search web links without relying on browser sync or third-party services.

## Implementation
Deployed as a Kubernetes Deployment with persistent storage for the SQLite database.

## Stack
Kubernetes Deployment (Kustomize via Flux)

## LLD
- Namespace: linkding
- Image: sissbruecker/linkding:latest
- Port: tcp/9090
- Volume: linkding-pvc mounted at /etc/linkding/data
- Dependencies: None (standalone SQLite)
