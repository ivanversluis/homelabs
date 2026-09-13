# Anthropic through Kong AI Gateway

## Purpose

Open WebUI and OpenClaw use one OpenAI-compatible endpoint exposed by Kong:

```text
Open WebUI ----\
                -> Kong key-auth -> Kong AI Proxy -> Anthropic API
OpenClaw ------/       |                 |
                       |                 +-- x-api-key: <Anthropic key from Vault>
                       +-- internal client key
```

The Anthropic API key is owned by Kong and never exposed to Open WebUI or OpenClaw.

## Vault prerequisites

Use the existing `secret` KV engine and the existing Kong path:

```text
secret/infra/kong
```

Add these properties:

| Property | Purpose |
|---|---|
| `anthropic-api-key` | Real Anthropic API key (`sk-ant-...`) used only by Kong upstream |
| `ai-gateway-client-key` | Random internal credential used by Open WebUI/OpenClaw to authenticate to Kong |

Do not use `vault kv put` because the path already contains Azure AI settings. Patch the existing secret instead:

```bash
export ANTHROPIC_API_KEY='sk-ant-...'
export AI_GATEWAY_CLIENT_KEY="$(openssl rand -hex 32)"

vault kv patch secret/infra/kong \
  anthropic-api-key="$ANTHROPIC_API_KEY" \
  ai-gateway-client-key="$AI_GATEWAY_CLIENT_KEY"
```

Do not commit either value to Git.

## Runtime flow

### Open WebUI

Open WebUI keeps the existing OpenAI-compatible endpoint:

```text
https://ai.${DOMAIN}/v1
```

Its `OPENAI_API_KEY` is sourced from `secret/infra/kong:ai-gateway-client-key` through External Secrets. It is an internal Kong credential, not the Anthropic key.

### OpenClaw

OpenClaw configures a custom OpenAI-compatible provider:

```text
provider: kong
base URL: https://ai.${DOMAIN}/v1
model: kong/claude-sonnet-4-6
API: openai-completions
```

The provider API key is a SecretRef to `KONG_AI_GATEWAY_KEY`, sourced from the same internal Kong client credential.

The OpenClaw container startup wrapper applies the Kong provider after the existing init containers have completed. It also removes persisted non-Kong per-agent/session model overrides so existing sessions fall back to `kong/claude-sonnet-4-6` instead of the previous OpenAI/Codex route.

### Kong

Kong performs four relevant operations on the chat route:

1. Convert `Authorization: Bearer <client-key>` into the `apikey` header expected by Kong key-auth.
2. Validate the internal `ai-gateway-client-key`.
3. Normalize the request model to `claude-sonnet-4-6`.
4. Use `ai-proxy` to translate the OpenAI-compatible request to Anthropic and inject the upstream `x-api-key` from Vault.

The existing Azure AI configuration remains in Git/Vault for rollback but is no longer attached to the active `/v1` route.

## Pre-merge validation

The two Vault values must exist before merging. Otherwise the Kong/OpenWebUI/OpenClaw ExternalSecrets cannot become Ready.

After adding the values, verify metadata/status without displaying secret contents:

```bash
kubectl -n kong get externalsecret \
  kong-anthropic-ai-proxy-config \
  kong-ai-gateway-client-key

kubectl -n ai get externalsecret openwebui-llm-gateway-key
kubectl -n openclaw get externalsecret openclaw-secrets
```

After reconciliation, verify generated Secrets exist without printing their data:

```bash
kubectl -n kong get secret \
  kong-anthropic-ai-proxy-config \
  kong-ai-gateway-client-key

kubectl -n ai get secret openwebui-llm-gateway-key
kubectl -n openclaw get secret openclaw-secrets
```

## API verification

Use the internal client key, never the Anthropic key, when testing Kong:

```bash
export DOMAIN='<homelab-domain>'
export AI_GATEWAY_CLIENT_KEY='<value of secret/infra/kong:ai-gateway-client-key>'
```

Model discovery:

```bash
curl -fsS "https://ai.${DOMAIN}/v1/models" \
  -H "Authorization: Bearer ${AI_GATEWAY_CLIENT_KEY}" | jq
```

Expected model:

```text
claude-sonnet-4-6
```

Chat completion:

```bash
curl -fsS "https://ai.${DOMAIN}/v1/chat/completions" \
  -H "Authorization: Bearer ${AI_GATEWAY_CLIENT_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model":"claude-sonnet-4-6",
    "messages":[{"role":"user","content":"Reply with exactly: kong-anthropic-ok"}],
    "max_tokens":32
  }' | jq
```

## Application verification

### Open WebUI

1. Confirm the OpenAI-compatible connection remains `https://ai.${DOMAIN}/v1`.
2. Refresh models.
3. Confirm `claude-sonnet-4-6` is visible.
4. Start a new chat and verify a completion succeeds.

### OpenClaw

Check the configured/default model using the OpenClaw CLI available in the pod, then start a fresh interaction. The effective default must be:

```text
kong/claude-sonnet-4-6
```

If an old conversation still behaves unexpectedly, inspect the persisted session configuration for a stale `model` property before changing anything else.

## Network-policy notes

- Open WebUI already has explicit egress to Kong.
- OpenClaw has a dedicated egress policy to the Kong namespace on proxy ports 8000/8443.
- Kong already has HTTPS internet egress required for external AI providers.

## Rollback

Prefer reverting the Git commit/PR so the Kong route, static model list, application secrets, OpenClaw default model, and network policy return together. The Azure AI resources and existing Vault values are retained, so the old backend can be restored without recreating its secrets.
