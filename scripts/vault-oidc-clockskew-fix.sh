#!/usr/bin/env bash
set -euo pipefail

# Diagnose and remediate Vault OIDC login failures caused by clock skew.
#
# Usage:
#   VAULT_TOKEN=... ./scripts/vault-oidc-clockskew-fix.sh
#   VAULT_TOKEN=... ./scripts/vault-oidc-clockskew-fix.sh <role-name>
#
# Optional env vars:
#   VAULT_NS=vault
#   VAULT_LABEL=app.kubernetes.io/name=vault
#   CLOCK_SKEW_LEEWAY=120
#   NOT_BEFORE_LEEWAY=120
#   EXPIRATION_LEEWAY=120

VAULT_NS="${VAULT_NS:-vault}"
VAULT_LABEL="${VAULT_LABEL:-app.kubernetes.io/name=vault}"
ROLE_NAME="${1:-${VAULT_OIDC_ROLE:-}}"

CLOCK_SKEW_LEEWAY="${CLOCK_SKEW_LEEWAY:-120}"
NOT_BEFORE_LEEWAY="${NOT_BEFORE_LEEWAY:-120}"
EXPIRATION_LEEWAY="${EXPIRATION_LEEWAY:-120}"

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err() { echo "[ERROR] $*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Missing required command: $1"
    exit 1
  }
}

require_cmd kubectl
require_cmd jq

info "Discovering Vault pod in namespace '$VAULT_NS'..."
VAULT_POD="$((kubectl get pod -n "$VAULT_NS" -l "$VAULT_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true)"

if [ -z "$VAULT_POD" ]; then
  err "No Vault pod found in namespace '$VAULT_NS' with label '$VAULT_LABEL'."
  exit 1
fi

info "Using Vault pod: $VAULT_POD"

echo
info "Recent Vault log lines related to OIDC/JWT validation:"
kubectl logs -n "$VAULT_NS" "$VAULT_POD" --tail=500 2>/dev/null \
  | grep -Ei 'oidc|jwt|invalid issued at|token is not valid yet|iat|nbf|exp' \
  || warn "No matching OIDC/JWT lines found in the last 500 lines."

echo
info "Checking clock skew between local machine and Vault pod..."
LOCAL_EPOCH="$(date -u +%s)"
POD_EPOCH="$(kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- date -u +%s)"
SKEW="$((LOCAL_EPOCH - POD_EPOCH))"
ABS_SKEW="${SKEW#-}"

echo "  local UTC epoch: $LOCAL_EPOCH"
echo "  vault UTC epoch: $POD_EPOCH"
echo "  skew (seconds):  $SKEW"

if [ "$ABS_SKEW" -gt 30 ]; then
  warn "Clock skew is >30s. This can break OIDC validation for iat/nbf claims."
  warn "Fix NTP on cluster nodes first (chronyd or systemd-timesyncd)."
else
  info "Clock skew is within acceptable range (<30s)."
fi

if [ -z "${VAULT_TOKEN:-}" ]; then
  echo
  warn "VAULT_TOKEN is not set; skipping automatic role remediation."
  echo "Set VAULT_TOKEN and re-run to apply leeway values automatically."
  exit 0
fi

if [ -z "$ROLE_NAME" ]; then
  info "No role provided. Reading default OIDC role from auth/oidc/config..."
  ROLE_NAME="$(kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_TOKEN="$VAULT_TOKEN" vault read -format=json auth/oidc/config \
    | jq -r '.data.default_role // empty')"
fi

if [ -z "$ROLE_NAME" ]; then
  err "Could not determine OIDC role. Pass role name as first argument."
  exit 1
fi

echo
info "Target OIDC role: $ROLE_NAME"

CURRENT_ROLE_JSON="$(kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
  env VAULT_TOKEN="$VAULT_TOKEN" vault read -format=json "auth/oidc/role/$ROLE_NAME")"

CURRENT_CLOCK="$(echo "$CURRENT_ROLE_JSON" | jq -r '.data.clock_skew_leeway // "<unset>"')"
CURRENT_NBF="$(echo "$CURRENT_ROLE_JSON" | jq -r '.data.not_before_leeway // "<unset>"')"
CURRENT_EXP="$(echo "$CURRENT_ROLE_JSON" | jq -r '.data.expiration_leeway // "<unset>"')"

echo "  current clock_skew_leeway: $CURRENT_CLOCK"
echo "  current not_before_leeway: $CURRENT_NBF"
echo "  current expiration_leeway: $CURRENT_EXP"

echo
info "Applying OIDC role leeway fix..."
kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
  env VAULT_TOKEN="$VAULT_TOKEN" vault write "auth/oidc/role/$ROLE_NAME" \
  clock_skew_leeway="$CLOCK_SKEW_LEEWAY" \
  not_before_leeway="$NOT_BEFORE_LEEWAY" \
  expiration_leeway="$EXPIRATION_LEEWAY" >/dev/null

UPDATED_ROLE_JSON="$(kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
  env VAULT_TOKEN="$VAULT_TOKEN" vault read -format=json "auth/oidc/role/$ROLE_NAME")"

UPDATED_CLOCK="$(echo "$UPDATED_ROLE_JSON" | jq -r '.data.clock_skew_leeway // "<unset>"')"
UPDATED_NBF="$(echo "$UPDATED_ROLE_JSON" | jq -r '.data.not_before_leeway // "<unset>"')"
UPDATED_EXP="$(echo "$UPDATED_ROLE_JSON" | jq -r '.data.expiration_leeway // "<unset>"')"

echo "  updated clock_skew_leeway: $UPDATED_CLOCK"
echo "  updated not_before_leeway: $UPDATED_NBF"
echo "  updated expiration_leeway: $UPDATED_EXP"

echo
info "Remediation complete. Retry OIDC login in Vault UI."
info "If login still fails, verify node NTP sync and IDP/server clock alignment."
