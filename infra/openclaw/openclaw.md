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
Store the OpenClaw secret at path `infra/openclaw` in Vault with these properties:

- `OPENCLAW_GATEWAY_TOKEN` (required)
- `DISCORD_TOKEN` (required)
- `DISCORD_BOT_TOKEN` is injected into the pod from `DISCORD_TOKEN` for OpenClaw's Discord send path
- `OPENROUTER_API_KEY` (required — primary/default LLM provider)
- `AZURE_FOUNDRY_API_KEY` (required — Azure AI Foundry API key)
- `AZURE_FOUNDRY_ENDPOINT` (required — Azure AI Foundry base URL, e.g. `https://<name>.cognitiveservices.azure.com`; kept out of the repo)
- `OPENCLAW_ALLOWED_ORIGINS` (required when binding gateway on LAN; comma-separated origins)
- `OPENCLAW_TRUSTED_PROXIES` (recommended behind Cloudflare Tunnel; comma-separated CIDRs)

OpenRouter (`openrouter/free`) is the default model. Azure AI Foundry is registered as a second
provider (`azure-foundry`) and its endpoint URL is injected at pod start from the Vault secret —
it is never stored in the Git repo.

Retrieve the Azure Foundry API key and endpoint from Terraform output (sensitive):
```bash
cd InfraAutomation-ng/dev/compute/rg-ivan-ai-foundry
terraform output -raw api_key_primary
terraform output ai_foundry_endpoint
```

Example:

```bash
vault kv put kv/infra/openclaw \
  OPENCLAW_GATEWAY_TOKEN="<generated-token>" \
  DISCORD_TOKEN="<discord-bot-token>" \
  OPENROUTER_API_KEY="<openrouter-api-key>" \
  AZURE_FOUNDRY_API_KEY="<terraform-output-api_key_primary>" \
  AZURE_FOUNDRY_ENDPOINT="<terraform-output-ai_foundry_endpoint>" \
  OPENCLAW_ALLOWED_ORIGINS="https://openclaw,http://127.0.0.1:18789,http://localhost:18789" \
  OPENCLAW_TRUSTED_PROXIES="10.244.0.0/16"
```

To switch active model to Azure AI Foundry, either use the OpenClaw UI or patch the cron/config
via the agent: `providers.azure-foundry` is pre-registered and selectable as `azure-foundry/gpt-4o-mini`
or `azure-foundry/phi-4`.

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



The k8s-monitor skill calls the Kubernetes API directly using the pod's service
account (no `kubectl` binary needed). Use the helper script to test it:

```bash
./scripts/openclaw-k8s-monitor-report.sh
```

Optional environment overrides:

- `OPENCLAW_NAMESPACE` (default: `openclaw`)
- `OPENCLAW_SELECTOR` (default: `app.kubernetes.io/name=openclaw`)

After updating the ConfigMap, restart the pod so the init container re-copies
the skill files from the ConfigMap to the persistent volume:

```bash
kubectl rollout restart deployment/openclaw -n openclaw
kubectl rollout status deployment/openclaw -n openclaw
```
