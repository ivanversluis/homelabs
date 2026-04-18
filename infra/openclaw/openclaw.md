# OpenClaw Homelab Wiki

## Documentation
https://github.com/openclaw/openclaw
https://github.com/openclaw/openclaw/blob/main/docs/install/kubernetes.md

## Releases
https://github.com/openclaw/openclaw/releases

## Current Version
- OpenClaw release: `v2026.4.14`
- Container image: `ghcr.io/openclaw/openclaw:2026.4.14` (pinned)

## Objective
Run an AI Kubernetes operations agent inside the homelab cluster that monitors events, unhealthy pods, and node pressure, then reports actionable alerts to Discord.

## Implementation
OpenClaw is deployed as Kubernetes manifests under `infra/openclaw` (Flux-managed via Kustomize). It uses:
- A persistent volume for OpenClaw runtime state
- Read-only cluster RBAC for monitoring
- ExternalSecret backed by Vault for all runtime secrets
- ConfigMap for `openclaw.json`, `AGENTS.md`, and `k8s-monitor.js`

## Vault secret requirements
Store the OpenClaw secret at path `infra/openclaw` in Vault with these properties:

- `OPENCLAW_GATEWAY_TOKEN` (required)
- `DISCORD_TOKEN` (required)
- `OPENROUTER_API_KEY` (required for OpenRouter model provider)

Example:

```bash
vault kv put kv/infra/openclaw \
  OPENCLAW_GATEWAY_TOKEN="<generated-token>" \
  DISCORD_TOKEN="<discord-bot-token>" \
  OPENROUTER_API_KEY="<openrouter-api-key>"
```

Only the OpenRouter key is used for LLM calls.

## Validation commands

```bash
kubectl kustomize infra/openclaw >/dev/null
kubectl kustomize infra >/dev/null
kubectl kustomize clusters/k8s-homelab >/dev/null
```
