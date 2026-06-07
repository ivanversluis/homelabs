# OpenClaw Homelab Wiki

## Documentation
https://github.com/openclaw/openclaw
https://github.com/openclaw/openclaw/blob/main/docs/install/kubernetes.md

## Releases
https://github.com/openclaw/openclaw/releases

## Current Version
- OpenClaw release: `v2026.4.23`
- Container image: `ghcr.io/openclaw/openclaw:2026.4.23` (pinned)

## Objective
Run an AI Kubernetes operations agent inside the homelab cluster that monitors events, unhealthy pods, and node pressure, then reports actionable alerts to Discord.

## Implementation
OpenClaw is deployed as Kubernetes manifests under `infra/openclaw` (Flux-managed via Kustomize). It uses:
- A persistent volume for OpenClaw runtime state
- Read-only cluster RBAC for monitoring
- ExternalSecret backed by Vault for all runtime secrets
- ConfigMap for `openclaw.json`, `AGENTS.md`, and `k8s-monitor.js`

## Vault secret requirements
Store the OpenClaw runtime secret at path `infra/openclaw` in Vault with these properties:

- `OPENCLAW_GATEWAY_TOKEN` (required)
- `DISCORD_TOKEN` (required)
- `DISCORD_BOT_TOKEN` is injected into the pod from `DISCORD_TOKEN` for OpenClaw's Discord send path
- `OPENROUTER_API_KEY` (optional fallback LLM provider)
- `AZURE_API_KEY` (required — Azure AI Foundry / Cognitive Services primary key)
- `AZURE_RESOURCE_NAME` (required — the resource name portion of the FQDN, e.g. `aifoundry-openclaw-dev` for `aifoundry-openclaw-dev.cognitiveservices.azure.com`; kept out of the repo)
- `OPENCLAW_ALLOWED_ORIGINS` (required when binding gateway on LAN; comma-separated origins)
- `OPENCLAW_TRUSTED_PROXIES` (recommended behind Cloudflare Tunnel; comma-separated CIDRs)

- `CODEX` (required — Codex/OpenAI auth material)

OpenAI Codex (`openai/gpt-5.5`) is the default model. The deployment seeds the
main OpenClaw agent auth profile from the Vault `CODEX` property without logging
the secret. Azure AI Foundry is auto-discovered as the `azure` provider via the
standard `AZURE_API_KEY` and `AZURE_RESOURCE_NAME` env vars.
Models show up as `azure/gpt-4o-mini` and `azure/phi-4` in the UI/CLI.

Retrieve the Azure API key from Terraform output (sensitive):
```bash
cd InfraAutomation-ng/dev/compute/rg-ivan-ai-foundry
terraform output -raw api_key_primary
terraform output ai_foundry_endpoint   # extract the resource name from the FQDN
```

Example:

```bash
vault kv put kv/infra/openclaw \
  OPENCLAW_GATEWAY_TOKEN="<generated-token>" \
  DISCORD_TOKEN="<discord-bot-token>" \
  OPENROUTER_API_KEY="<openrouter-api-key>" \
  OPENCLAW_ALLOWED_ORIGINS="https://openclaw.$DOMAIN$,http://127.0.0.1:18789,http://localhost:18789" \
  OPENCLAW_TRUSTED_PROXIES="10.244.0.0/16"
```

Add or rotate the Codex auth material in the same Vault secret:

```bash
vault kv patch secret/infra/openclaw CODEX="<codex-auth-or-api-key>"
```

To switch the active model to Azure, use the OpenClaw UI model picker or:
`openclaw config set agents.defaults.model azure/gpt-4o-mini`
Available Azure models: `azure/gpt-4o-mini`, `azure/phi-4`.

## Validation commands

```bash
kubectl kustomize infra/openclaw >/dev/null
kubectl kustomize infra >/dev/null
kubectl kustomize clusters/k8s-homelab >/dev/null
```

## Discord troubleshooting

### `Failed to resolve Discord application id` / `message failed: 401`

**Cause**: `DISCORD_TOKEN` in Vault is a webhook URL, not a Discord bot token.
OpenClaw connects to Discord via the WebSocket gateway and requires a bot token.

**Fix**: Create a Discord bot (see `openclaw-secrets.md-local` for full steps),
then update Vault:

```bash
vault kv patch kv/infra/openclaw DISCORD_TOKEN="<bot-token>"
kubectl rollout restart deployment/openclaw -n openclaw
```

After restart, watch logs to confirm the channel connects:

```bash
kubectl logs -n openclaw deployment/openclaw -f | grep discord
# Expected: [discord] [default] ready
```

### Target channel format

The agent must use `channel:<id>` prefix when calling the message tool.
Bare numeric IDs are rejected by openclaw as ambiguous.
The `#homelab` channel ID is hardcoded in the skill as `1498285999552204810`.



The k8s-monitor script calls the Kubernetes API directly using the pod's service
account (no `kubectl` binary needed). It is scheduled by the
`openclaw-k8s-monitor` Kubernetes CronJob every 4 hours. Do not schedule this
through OpenClaw cron, because that wakes an LLM agent and wastes tokens for a
deterministic health check. Each run posts a Discord status message; non-ok
reports still fail the Kubernetes Job if Discord delivery fails.

Use the helper script to test it:

```bash
./scripts/openclaw-k8s-monitor-report.sh
```

Optional environment overrides:

- `OPENCLAW_NAMESPACE` (default: `openclaw`)
- `OPENCLAW_SELECTOR` (default: `app.kubernetes.io/name=openclaw`)

After updating the ConfigMap, restart the pod if you need the interactive agent
to use the latest PVC copy. The Kubernetes CronJob reads the script directly
from the ConfigMap:

```bash
kubectl rollout restart deployment/openclaw -n openclaw
kubectl rollout status deployment/openclaw -n openclaw
```
