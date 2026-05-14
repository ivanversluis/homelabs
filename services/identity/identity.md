# Identity Service (Authentik) Homelab wiki

## Documentation
https://docs.goauthentik.io/

## Repo
https://github.com/goauthentik/authentik

## Releases
https://ghcr.io/goauthentik/server

## Latest version
2026.2.2

## Objective
As home-admin I want a centralized identity provider (IdP) for SSO/OIDC authentication across all homelab services, eliminating per-app credentials.

## Implementation
Authentik server deployed as a Kubernetes Deployment with PostgreSQL and Redis dependencies. Provides OIDC/OAuth2 for Homepage, Homebox, Headlamp, Open WebUI, and other services.

## Stack
Kubernetes Deployment (Kustomize via Flux)

## LLD
- Namespace: identity (authentik-server deployment)
- Image: ghcr.io/goauthentik/server:2026.2.2
- Ports: tcp/9000 (HTTP), tcp/9443 (HTTPS)
- Database: PostgreSQL (separate deployment)
- Cache: Redis (separate deployment)
- Security: runAsUser 1000, runAsNonRoot
- Volume: PVC for media/templates
- Dependencies: ExternalSecret (Vault) for PG credentials, secret key
