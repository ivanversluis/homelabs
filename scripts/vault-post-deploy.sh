#!/bin/bash
# scripts/vault-post-deploy.sh
# Post-deployment script for HashiCorp Vault on Flux-managed k8s-homelab.
#
# Run this ONCE after Flux has deployed the Vault HelmRelease and the pod is
# running (it will be sealed/uninitialized). The script handles:
#   1. Waiting for the Vault pod
#   2. Initializing Vault (or unsealing if already initialized)
#   3. Enabling KV v2 at "secret/"
#   4. Enabling Kubernetes auth
#   5. Creating the "external-secrets" role so the ESO ClusterSecretStore works
#
# Existing Vault data is preserved — the script detects an already-initialized
# Vault and only unseals it.
#
# Usage:
#   ./scripts/vault-post-deploy.sh
#   ./scripts/vault-post-deploy.sh /path/to/vault-keys.json   # provide existing keys
#
set -euo pipefail

KEYS_FILE="${1:-}"
VAULT_NS="vault"
ESO_NS="external-secrets-system"

# ─── helpers ───────────────────────────────────────────────────────────────────
info()  { echo "ℹ️  $*"; }
ok()    { echo "✅ $*"; }
warn()  { echo "⚠️  $*"; }
fail()  { echo "❌ $*" >&2; exit 1; }

require_cmd() { command -v "$1" &>/dev/null || fail "$1 is required but not found"; }

vault_exec() {
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- env VAULT_TOKEN="${VAULT_TOKEN:-}" "$@"
}

# ─── pre-flight ────────────────────────────────────────────────────────────────
require_cmd kubectl
require_cmd jq

info "Waiting for Vault pod in namespace '$VAULT_NS'..."
kubectl wait --for=condition=Initialized pod -l app.kubernetes.io/name=vault \
  -n "$VAULT_NS" --timeout=300s 2>/dev/null || true

VAULT_POD=$(kubectl get pod -n "$VAULT_NS" -l app.kubernetes.io/name=vault \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) \
  || fail "No Vault pod found in namespace '$VAULT_NS'. Is the HelmRelease synced?"

info "Using pod: $VAULT_POD"
echo ""

# ─── step 1 – initialize or unseal ────────────────────────────────────────────
ALREADY_INIT=false
if kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- vault status 2>&1 | grep -q "Initialized.*true"; then
  ALREADY_INIT=true
fi

if $ALREADY_INIT; then
  warn "Vault is already initialized."

  # Locate keys file
  if [ -z "$KEYS_FILE" ]; then
    KEYS_FILE=$(ls -t vault-keys-*.json 2>/dev/null | head -1 || true)
  fi

  if [ -z "$KEYS_FILE" ] || [ ! -f "$KEYS_FILE" ]; then
    fail "Vault is initialized but no keys file found. Provide path as argument: $0 /path/to/vault-keys.json"
  fi

  ok "Using keys from $KEYS_FILE"
  VAULT_TOKEN=$(jq -r '.root_token' "$KEYS_FILE")

  # Unseal if sealed
  if kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- vault status 2>&1 | grep -q "Sealed.*true"; then
    info "Unsealing Vault..."
    mapfile -t KEYS < <(jq -r '.unseal_keys_b64[]' "$KEYS_FILE")
    for i in 0 1 2; do
      info "  key $((i+1))/3"
      kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- vault operator unseal "${KEYS[$i]}" >/dev/null
    done
    ok "Vault unsealed"
  else
    ok "Vault is already unsealed"
  fi

else
  info "Initializing Vault (5 shares, threshold 3)..."
  INIT_OUTPUT=$(kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- vault operator init \
    -key-shares=5 -key-threshold=3 -format=json)

  KEYS_FILE="vault-keys-$(date +%Y%m%d-%H%M%S).json"
  echo "$INIT_OUTPUT" > "$KEYS_FILE"
  chmod 600 "$KEYS_FILE"
  ok "Vault initialized — keys saved to $KEYS_FILE"
  warn "MOVE THIS FILE TO A SECURE LOCATION IMMEDIATELY!"
  echo ""

  echo "Unseal Keys:"
  echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[]' | nl -w2 -s'. '
  echo ""
  VAULT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')
  echo "Root Token: $VAULT_TOKEN"
  echo ""

  # Unseal
  mapfile -t KEYS < <(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[]')
  for i in 0 1 2; do
    info "Unsealing with key $((i+1))/3..."
    kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- vault operator unseal "${KEYS[$i]}" >/dev/null
  done
  ok "Vault unsealed"
fi

echo ""
kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- vault status
echo ""

# ─── step 2 – enable KV v2 ────────────────────────────────────────────────────
info "Enabling KV v2 secrets engine at secret/..."
vault_exec vault secrets enable -path=secret kv-v2 2>/dev/null \
  && ok "KV v2 enabled" \
  || ok "KV v2 already enabled"
echo ""

# ─── step 3 – enable & configure Kubernetes auth ──────────────────────────────
info "Enabling Kubernetes auth method..."
vault_exec vault auth enable kubernetes 2>/dev/null \
  && ok "Kubernetes auth enabled" \
  || ok "Kubernetes auth already enabled"

info "Configuring Kubernetes auth..."
vault_exec sh -c 'vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"'
ok "Kubernetes auth configured"
echo ""

# ─── step 4 – create policies ─────────────────────────────────────────────────
info "Creating Vault policies..."

# Broad read-only policy for ESO — adjust paths as needed
vault_exec sh -c 'vault policy write external-secrets-operator - <<POLICY
# Allow ESO to read all application secrets
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
POLICY'
ok "Policy 'external-secrets-operator' created"
echo ""

# ─── step 5 – create Kubernetes auth role for ESO ─────────────────────────────
info "Creating Kubernetes auth role 'external-secrets'..."
vault_exec vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets-operator \
  bound_service_account_namespaces="$ESO_NS" \
  policies=external-secrets-operator \
  ttl=24h
ok "Role 'external-secrets' created"
echo ""

# ─── done ──────────────────────────────────────────────────────────────────────
echo "======================================================"
ok "Vault post-deployment setup complete!"
echo "======================================================"
echo ""
echo "Vault UI:  kubectl port-forward -n vault svc/vault 8200:8200"
echo "           then open http://localhost:8200"
echo ""
echo "Next steps:"
echo "  1. Store your application secrets in Vault (see migration docs)"
echo "  2. Commit & push the homelabs branch so Flux picks up the ClusterSecretStore"
echo "  3. Create ExternalSecret resources per application/namespace"
echo ""
if [ "$ALREADY_INIT" = false ]; then
  echo "CRITICAL: Secure $KEYS_FILE now and delete it from this machine!"
fi
