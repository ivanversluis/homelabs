# n8n Homelab wiki

## Documentation
https://docs.n8n.io/

## Repo
https://github.com/n8n-io/n8n

## Releases
https://hub.docker.com/r/n8nio/n8n

## Latest version
2.20.6

## Objective
As home-admin I want a self-hosted workflow automation platform to connect services, automate tasks, and build integrations without vendor lock-in.

## Implementation
Deployed as a Kubernetes Deployment with a dedicated PostgreSQL sidecar database. Secrets managed via ExternalSecret operator backed by Vault.

## Stack
Kubernetes Deployment (Kustomize via Flux)

## LLD
- Namespace: n8n
- Image: n8nio/n8n:2.20.6
- Port: tcp/5678
- Volume: n8n-pvc mounted at /home/node/.n8n (Longhorn)
- Database: PostgreSQL (separate deployment in same namespace)
- Security: runAsUser 1000, runAsNonRoot
- Dependencies: ExternalSecret (Vault) for DB password, encryption key, basic auth credentials
