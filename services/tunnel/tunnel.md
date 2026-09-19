# Tunnel (Cloudflare Tunnel) Homelab wiki

## Documentation
https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/

## Repo
https://github.com/cloudflare/cloudflared

## Releases
https://hub.docker.com/r/cloudflare/cloudflared

## Latest version
2026.8.3

## Objective
As home-admin I want a secure outbound tunnel to Cloudflare so that external users can access homelab services without exposing ports or requiring a public IP.

## Implementation
Deployed as a Kubernetes Deployment with 2 replicas. Scheduling excludes control-plane/master nodes and uses required pod anti-affinity on `kubernetes.io/hostname` so replicas land on different worker nodes. Tunnel token is shared across replicas via ExternalSecret from Vault.

## Stack
Kubernetes Deployment (Kustomize via Flux)

## LLD
- Namespace: cloudflared
- Image: cloudflare/cloudflared:2026.8.3
- Port: tcp/2000 (metrics)
- Health: /ready endpoint on port 2000
- Replicas: 2
- Placement: worker nodes only (`node-role.kubernetes.io/control-plane/master` excluded) + required pod anti-affinity by hostname
- Dependencies: ExternalSecret (Vault) for TUNNEL_TOKEN
- Monitoring: Gatus checks in `platform/observability/monitoring/gatus/gatus-configmap-config.yaml` (`10-cloudflare-public-routes.yaml`) verify published-route availability during node maintenance
