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
[[ -t 0 && -t 1 ]] || { echo "ERROR: interactive terminal required (stdin and stdout TTY)" >&2; exit 1; }
umask 077
pods="$(kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=$RELEASE,component=server" -o json | jq -r '.items[].metadata.name' | sort -V)"
[[ -n "$pods" ]] || { echo "ERROR: no Vault server pods in $NS" >&2; exit 1; }
echo "Vault server pods in $NS: $pods"
for pod in $pods; do
  echo "Inspecting $pod..."
  # "vault status" exits 2 for sealed, so inspect JSON even with a non-zero exit.
  status="$(kubectl -n "$NS" exec "$pod" -- vault status -format=json 2>/dev/null)" || true
  [[ -n "$status" ]] && jq -e '.initialized | type == "boolean"' <<<"$status" >/dev/null || {
    echo "ERROR: $pod status unavailable or invalid" >&2; exit 1;
  }
  initialized="$(jq -r '.initialized' <<<"$status")"
  sealed="$(jq -r '.sealed' <<<"$status")"
  [[ "$initialized" == true ]] || { echo "ERROR: $pod is uninitialized; stop (never init)" >&2; exit 1; }
  if [[ "$sealed" == false ]]; then echo "$pod is unsealed"; continue; fi
  threshold="$(jq -r '.t // empty' <<<"$status")"
  [[ "$threshold" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: missing Shamir threshold" >&2; exit 1; }
  echo "$pod is sealed (threshold: $threshold). Vault will prompt for distinct shares."
  echo "Use authorized custodians; never put shares in shell arguments, history, tickets or logs."
  for ((i=1; i<=threshold; i++)); do
    echo "Submit distinct share $i/$threshold to $pod (input hidden by Vault CLI):"
    # HashiCorp Vault operator unseal treats '-' as a literal key, NOT stdin.
    # Use its interactive TTY prompt so the share never appears in argv or script variables.
    kubectl -n "$NS" exec -it "$pod" -- vault operator unseal
    current="$(kubectl -n "$NS" exec "$pod" -- vault status -format=json 2>/dev/null)" || true
    [[ -n "$current" ]] && jq -e '.sealed | type == "boolean"' <<<"$current" >/dev/null || {
      echo "ERROR: cannot verify seal progress on $pod" >&2; exit 1;
    }
    if [[ "$(jq -r '.sealed' <<<"$current")" == false ]]; then break; fi
  done
  final="$(kubectl -n "$NS" exec "$pod" -- vault status -format=json 2>/dev/null)" || {
    echo "ERROR: cannot verify $pod" >&2; exit 1;
  }
  [[ "$(jq -r '.sealed' <<<"$final")" == false ]] || { echo "ERROR: $pod remains sealed" >&2; exit 1; }
  echo "$pod successfully unsealed"
done
echo "All discovered Vault members unsealed. Validate Raft peers and ESO separately."
