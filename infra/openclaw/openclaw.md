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
- `DISCORD_BOT_TOKEN` is injected into the pod from `DISCORD_TOKEN` for OpenClaw's Discord send path
- `OPENROUTER_API_KEY` (required for OpenRouter model provider)
- `OPENCLAW_ALLOWED_ORIGINS` (required when binding gateway on LAN; comma-separated origins)
- `OPENCLAW_TRUSTED_PROXIES` (recommended behind Cloudflare Tunnel; comma-separated CIDRs)

Example:

```bash
vault kv put kv/infra/openclaw \
  OPENCLAW_GATEWAY_TOKEN="<generated-token>" \
  DISCORD_TOKEN="<discord-bot-token>" \
  OPENROUTER_API_KEY="<openrouter-api-key>" \
  OPENCLAW_ALLOWED_ORIGINS="https://openclaw.example.invalid,http://127.0.0.1:18789,http://localhost:18789" \
  OPENCLAW_TRUSTED_PROXIES="10.244.0.0/16"
```

Only the OpenRouter key is used for LLM calls.

## Validation commands

```bash
kubectl kustomize infra/openclaw >/dev/null
kubectl kustomize infra >/dev/null
kubectl kustomize clusters/k8s-homelab >/dev/null
```

## Run k8s-monitor report directly

If the OpenClaw skill list is not showing `k8s-monitor`, run the mounted skill file
directly from this repo helper script:

```bash
./scripts/openclaw-k8s-monitor-report.sh
```

Optional environment overrides:

- `OPENCLAW_NAMESPACE` (default: `openclaw`)
- `OPENCLAW_SELECTOR` (default: `app.kubernetes.io/name=openclaw`)

## OpenClaw UI chat prompts (recommended)

Use these prompts in Control UI chat to avoid sandbox runtime issues:

```text
Run the k8s-monitor skill now using host=gateway and return only report JSON.
```

```text
If exec policy blocks commands, request allowlist approval for read-only kubectl commands and then continue.
```

If UI skill execution is blocked by sandbox/auth errors, keep using the script runner
as fallback:

```bash
./scripts/openclaw-k8s-monitor-report.sh
```
