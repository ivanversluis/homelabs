#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# iam-patch-authentik-redirect-uris.sh
# ─────────────────────────────────────────────────────────────────────────────
# Patches redirect_uris for all OIDC providers in Authentik.
# Run after Authentik upgrades which may clear redirect_uris from all providers.
#
# Usage:
#   make iam-patch-redirect-uris
#   bash scripts/iam-patch-authentik-redirect-uris.sh
#
# Requires: terraform.tfvars with authentik_url and authentik_token
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TF_VARS="automation/infra-as-code/terraform/deployments/terraform.tfvars"

if [[ ! -f "$TF_VARS" ]]; then
  echo "ERROR: $TF_VARS not found. Run from the homelabs repo root." >&2
  exit 1
fi

AURL=$(grep '^authentik_url' "$TF_VARS" | awk -F '"' '{print $2}')
ATOK=$(grep '^authentik_token' "$TF_VARS" | awk -F '"' '{print $2}')
D=$(kubectl get secret flux-domain-vars -n flux-system -o jsonpath='{.data.DOMAIN}' | base64 -d)

if [[ -z "$D" ]]; then
  echo "ERROR: Cannot resolve domain from flux-domain-vars secret" >&2
  exit 1
fi

echo "Authentik URL: $AURL"
echo "Domain:        $D"
echo ""

patch_provider() {
  local id=$1
  local name=$2
  shift 2
  local -a uris=("$@")

  local payload
  payload=$(python3 -c "
import json, sys
uris = sys.argv[1:]
payload = {'redirect_uris': [{'matching_mode': 'strict', 'url': u} for u in uris]}
print(json.dumps(payload))
" "${uris[@]}")

  local http_code
  http_code=$(curl -s -o /tmp/authentik_patch_${id}.json -w "%{http_code}" \
    -X PATCH "${AURL}/api/v3/providers/oauth2/${id}/" \
    -H "Authorization: Bearer ${ATOK}" \
    -H "Content-Type: application/json" \
    -d "$payload")

  if [[ "$http_code" == "200" ]]; then
    echo "✓ ${name} (id=${id}): redirect_uris set to: ${uris[*]}"
  else
    echo "✗ ${name} (id=${id}): HTTP ${http_code}"
    cat "/tmp/authentik_patch_${id}.json" >&2
    return 1
  fi
}

echo "Patching redirect URIs for all registered providers..."
echo ""

# Provider IDs are stable Authentik PKs - update if providers are recreated.
# To find provider IDs: curl -s -H "Authorization: Bearer $ATOK" "$AURL/api/v3/providers/oauth2/?ordering=pk" | python3 -c "import json,sys; [print(p['pk'], p['name']) for p in json.load(sys.stdin)['results']]"
patch_provider 19 "ArgoCD"      "https://demo-argocd.${D}/auth/callback"
patch_provider 25 "Forgejo"     "https://forgejo.${D}/user/oauth2/authentik/callback"
patch_provider 11 "Headlamp"    "https://headlamp.${D}/oidc/callback" "https://k8s.${D}/oidc/callback"
patch_provider 13 "Homepage"    "https://homepage.${D}/api/auth/callback/authentik"
patch_provider 14 "Homebox"     "https://homebox.${D}/api/v1/users/login/oidc/callback"
patch_provider 22 "Longhorn"    "https://storage.${D}/oauth2/callback"
patch_provider 18 "SemaphoreUI" "https://demo-semaphore.${D}/api/auth/oidc/redirect"
patch_provider 21 "Termix"      "https://demo-termix.${D}/users/oidc/callback"

echo ""
echo "Done. Verify with:"
echo "  curl -s -H \"Authorization: Bearer \$ATOK\" \"\$AURL/api/v3/providers/oauth2/?ordering=pk\" | python3 -c \"import json,sys; [print(p['pk'], p['name'], [u['url'] for u in p.get('redirect_uris',[])]) for p in json.load(sys.stdin)['results']]\""
