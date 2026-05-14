# AI Stack Homelab wiki

## Documentation
https://docs.openwebui.com/

## Repo
https://github.com/open-webui/open-webui

## Releases
https://ghcr.io/open-webui/open-webui

## Latest version
v0.6.5

## Objective
As home-admin I want a self-hosted AI chat interface that routes LLM requests through Kong AI Gateway to Azure OpenAI, with OIDC authentication and rate limiting.

## Implementation
Open WebUI deployed as a Kubernetes Deployment in the ai namespace. LLM traffic is proxied via Kong AI Gateway (ai-proxy plugin) so that rate limiting, prompt guard, and logging apply transparently.

## Stack
Kubernetes Deployment (Kustomize via Flux)

## LLD
- Namespace: ai
- Image: ghcr.io/open-webui/open-webui:v0.6.5
- Port: tcp/8080
- Volume: PVC for /app/backend/data (Longhorn)
- Auth: Authentik OIDC
- Dependencies: Kong AI Gateway, ExternalSecret (Vault) for OIDC + API keys
