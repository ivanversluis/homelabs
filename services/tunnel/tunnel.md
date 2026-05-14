# Tunnel (Cloudflare Tunnel) Homelab wiki

## Documentation
https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/

## Repo
https://github.com/cloudflare/cloudflared

## Releases
https://hub.docker.com/r/cloudflare/cloudflared

## Latest version
2026.3.0

## Objective
As home-admin I want a secure outbound tunnel to Cloudflare so that external users can access homelab services without exposing ports or requiring a public IP.

## Implementation
Deployed as a Kubernetes Deployment with control-plane toleration. Tunnel token injected via ExternalSecret from Vault.

## Stack
Kubernetes Deployment (Kustomize via Flux)

## LLD
- Namespace: cloudflared
- Image: cloudflare/cloudflared:2026.3.0
- Port: tcp/2000 (metrics)
- Health: /ready endpoint on port 2000
- Tolerations: control-plane + master nodes
- Dependencies: ExternalSecret (Vault) for TUNNEL_TOKEN
