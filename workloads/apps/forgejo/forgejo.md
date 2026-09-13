# Forgejo Homelab wiki

## Documentation
https://forgejo.org/docs/latest/

## Repo
https://codeberg.org/forgejo/forgejo

## Releases
https://codeberg.org/forgejo/-/packages/container/forgejo

## Latest version
15.0.1-rootless

## Objective
As home-admin I want a self-hosted Git forge for private repositories, CI/CD pipelines, and code collaboration without relying on external providers.

## Implementation
Deployed as a Kubernetes Deployment with rootless image, secrets managed via ExternalSecret operator backed by Vault.

## Stack
Kubernetes Deployment (Kustomize via Flux)

## LLD
- Namespace: forgejo
- Image: codeberg.org/forgejo/forgejo:15.0.1-rootless
- Port: tcp/3000
- Volume: forgejo-pvc mounted at /var/lib/gitea (Longhorn)
- Security: runAsUser 1000, runAsNonRoot
- Dependencies: ExternalSecret (Vault) for SECRET_KEY, INTERNAL_TOKEN, JWT_SECRET
