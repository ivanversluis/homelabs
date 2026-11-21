# n8n (homelab)

## Objective

Self-hosted workflow automation on Kubernetes, managed by Flux CD with PostgreSQL and Vault-backed External Secrets.

## Deployment (source of truth)

- Manifest path: `workloads/apps/n8n/`
- Flux: `compute/eliteboxes/workloads/n8n-kustomization.yaml`
- Namespace: `n8n`; service: `n8n:80` -> container port `5678`
- Image: `n8nio/n8n:3.3.0-4078a9d` (early-access v3 candidate, **not approved for production**; deployment manifest pins the image digest)
- Application data: PVC `n8n-pvc`, mounted at `/home/node/.n8n`
- Database: PostgreSQL StatefulSet `n8n-postgres` with `n8n-postgres-pvc`
- Secrets: Vault KV `secret/apps/n8n` -> ExternalSecret `n8n-secrets`
- Security: non-root UID/GID 1000, namespace NetworkPolicies, `Recreate` rollout for the RWO app PVC

## AI Gateway

Kong provides an internal OpenAI-compatible endpoint at `https://llm-gw.<domain>/v1`. Connect with the n8n **OpenAI** credential, the internal gateway client key (Vault `secret/infra/kong`, property `AI_GATEWAY_CLIENT_KEY`) and model `claude-sonnet-4-6`. Do not put the API key or private domain in Git.

The n8n 3.0 migration and credential setup procedures are in [n8n AI Gateway / v3 migration runbook](../../../docs/lifecycle/n8n-v3-ai-gateway-migration.md).

## Documentation

- https://docs.n8n.io/
- https://github.com/n8n-io/n8n
- https://hub.docker.com/r/n8nio/n8n/tags
