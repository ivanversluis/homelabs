# Homepage Homelab wiki

## Documentation
https://gethomepage.dev/

## Repo
https://github.com/gethomepage/homepage

## Releases
https://ghcr.io/gethomepage/homepage

## Latest version
v1.13

## Objective
As home-admin I want a modern, self-hosted dashboard to aggregate all homelab services, bookmarks, and widgets in a single landing page.

## Implementation
Deployed as a Kubernetes Deployment with ConfigMap-driven configuration for services, widgets, and bookmarks. OIDC authentication via Authentik.

## Stack
Kubernetes Deployment (Kustomize via Flux)

## LLD
- Namespace: homepage
- Image: ghcr.io/gethomepage/homepage:v1.13
- Port: tcp/3000
- Volumes: ConfigMap mounted at /app/config (settings, services, widgets, bookmarks)
- Security: runAsUser 1000, runAsNonRoot
- Dependencies: ExternalSecret (Vault) for OIDC client credentials
