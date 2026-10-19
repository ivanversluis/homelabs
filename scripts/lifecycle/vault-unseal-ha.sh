#!/usr/bin/env bash
# Issue #256: operator-assisted Shamir unseal for initialized Vault members.
# Keys are entered on a trusted terminal, never passed as CLI args or stored by this script.
# Requires kubectl and jq. Never initializes Vault.
set -Eeuo pipefail
NS="${VAULT_NAMESPACE:-vault}"
RELEASE="${VAULT_RELEASE:-vault}"
[[ ${1:-} != --help ]] || { echo "Usage: VAULT_NAMESPACE=vault VAULT_RELEASE=vault $0"; exit 0; }
command -v kubectl >/dev/null
command -v jq >/dev/null
[[ -t 0 ]] || { echo "ERROR: interactive terminal required" >&2; exit 1; }
umask 077
pods="$(kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=$RELEASE,component=server" -o json | jq -r '.items[].metadata.name' | sort -V)"
[[ -n "$pods" ]] || { echo "ERROR: no Vault server pods in $NS" >&2; exit 1; }
echo "Vault server pods in $NS: $pods"
for pod in $pods; do
  echo "Inspecting $pod..."
  status="$(kubectl -n "$NS" exec "$pod" -- vault status -format=json 2>/dev/null)" || {
    echo "ERROR: $pod status unavailable; investigate rather than initialize" >&2; exit 1;
  }
  initialized="$(jq -r '.initialized' <<<"$status")"
  sealed="$(jq -r '.sealed' <<<"$status")"
  [[ "$initialized" == true ]] || { echo "ERROR: $pod is uninitialized; stop (never init)" >&2; exit 1; }
  if [[ "$sealed" == false ]]; then echo "$pod is unsealed"; continue; fi
  threshold="$(jq -r '.t // empty' <<<"$status")"
  [[ "$threshold" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: missing Shamir threshold" >&2; exit 1; }
  echo "$pod is sealed (threshold: $threshold). Enter distinct shares individually."
  echo "Use authorized custodians; do not paste shares into chat, ticket, or logs."
  for ((i=1; i<=threshold; i++)); do
    read -r -s -p "$pod unseal share $i/$threshold: " share
    echo
    [[ -n "$share" ]] || { echo "ERROR: empty share" >&2; exit 1; }
    # Feed stdin to vault CLI to avoid command-line/process-argument exposure.
    printf '%s\n' "$share" | kubectl -n "$NS" exec -i "$pod" -- vault operator unseal - >/dev/null
    unset share
    current="$(kubectl -n "$NS" exec "$pod" -- vault status -format=json 2>/dev/null)" || true
    if [[ -n "$current" ]] && [[ "$(jq -r '.sealed' <<<"$current")" == false ]]; then break; fi
  done
  final="$(kubectl -n "$NS" exec "$pod" -- vault status -format=json 2>/dev/null)" || {
    echo "ERROR: cannot verify $pod" >&2; exit 1;
  }
  [[ "$(jq -r '.sealed' <<<"$final")" == false ]] || { echo "ERROR: $pod remains sealed" >&2; exit 1; }
  echo "$pod successfully unsealed"
done
echo "All discovered Vault members unsealed. Validate Raft peers and ESO separately."
