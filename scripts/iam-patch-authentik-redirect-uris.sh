#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# iam-patch-authentik-redirect-uris.sh
# -----------------------------------------------------------------------------
# Patches redirect_uris for all OIDC providers in Authentik.
# Run after Authentik upgrades which may clear redirect_uris from all providers.
#
# Provider IDs are deliberately resolved by name at runtime. Authentik primary
# keys can change when a provider is recreated, so recovery must not depend on
# hardcoded IDs.
#
# Usage:
#   make iam-patch-redirect-uris
#   bash scripts/iam-patch-authentik-redirect-uris.sh
#   bash scripts/iam-patch-authentik-redirect-uris.sh --self-test
#
# Requires for normal operation:
#   terraform.tfvars with authentik_url and authentik_token
# -----------------------------------------------------------------------------
set -euo pipefail

resolve_provider_id_from_json() {
  local providers_json=$1
  local app_name=$2

  PROVIDERS_JSON="$providers_json" APP_NAME="$app_name" python3 - <<'PYCODE'
import json
import os
import sys

app_name = os.environ["APP_NAME"]
results = json.loads(os.environ["PROVIDERS_JSON"]).get("results", [])
provider_name = "Provider for " + app_name
expected = {app_name.casefold(), provider_name.casefold()}
matches = [
    provider
    for provider in results
    if str(provider.get("name", "")).casefold() in expected
]

if len(matches) == 1:
    print(matches[0]["pk"])
    raise SystemExit(0)

pool = matches if matches else results
available = ", ".join(
    "{}:{}".format(provider.get("pk"), provider.get("name"))
    for provider in pool
)

if matches:
    print(
        f"ERROR: Multiple Authentik OAuth2 providers match {app_name!r}: {available}",
        file=sys.stderr,
    )
else:
    print(
        f"ERROR: No Authentik OAuth2 provider found for {app_name!r}. "
        f"Expected {app_name!r} or {provider_name!r}. "
        f"Available providers: {available}",
        file=sys.stderr,
    )

raise SystemExit(1)
PYCODE
}


run_self_test() {
  local fixture
  fixture='{"results":[{"pk":19,"name":"Provider for ArgoCD"},{"pk":31,"name":"Provider for Gatus"},{"pk":22,"name":"Provider for Longhorn"},{"pk":13,"name":"Provider for Homepage"}]}'

  [[ "$(resolve_provider_id_from_json "$fixture" "ArgoCD")" == "19" ]]
  [[ "$(resolve_provider_id_from_json "$fixture" "Gatus")" == "31" ]]
  [[ "$(resolve_provider_id_from_json "$fixture" "Longhorn")" == "22" ]]
  [[ "$(resolve_provider_id_from_json "$fixture" "Homepage")" == "13" ]]

  if resolve_provider_id_from_json "$fixture" "MissingProvider" >/dev/null 2>&1; then
    echo "ERROR: provider lookup self-test accepted a missing provider" >&2
    return 1
  fi

  echo "OIDC redirect recovery self-test: OK"
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit 0
fi

TF_VARS="automation/infra-as-code/terraform/deployments/terraform.tfvars"

if [[ ! -f "$TF_VARS" ]]; then
  echo "ERROR: $TF_VARS not found. Run from the homelabs repo root." >&2
  exit 1
fi

AURL=$(grep '^authentik_url' "$TF_VARS" | awk -F '"' '{print $2}')
ATOK=$(grep '^authentik_token' "$TF_VARS" | awk -F '"' '{print $2}')
D=$(kubectl get secret flux-domain-vars -n flux-system -o jsonpath='{.data.DOMAIN}' | base64 -d)

if [[ -z "$AURL" || -z "$ATOK" ]]; then
  echo "ERROR: authentik_url/authentik_token missing from $TF_VARS" >&2
  exit 1
fi

if [[ -z "$D" ]]; then
  echo "ERROR: Cannot resolve domain from flux-domain-vars secret" >&2
  exit 1
fi

echo "Authentik URL: $AURL"
echo "Domain:        $D"
echo ""

echo "Resolving Authentik OAuth2 providers..."
PROVIDERS_JSON=$(curl -fsS -G \
  "${AURL}/api/v3/providers/oauth2/" \
  -H "Authorization: Bearer ${ATOK}" \
  --data-urlencode "ordering=pk" \
  --data-urlencode "page_size=100") || {
    echo "ERROR: Failed to query Authentik OAuth2 providers" >&2
    exit 1
  }

resolve_provider_id() {
  resolve_provider_id_from_json "$PROVIDERS_JSON" "$1"
}

patch_provider() {
  local name=$1
  shift
  local -a uris=("$@")

  local id
  id=$(resolve_provider_id "$name")

  local payload
  payload=$(python3 -c "
import json, sys
uris = sys.argv[1:]
payload = {'redirect_uris': [{'matching_mode': 'strict', 'url': u} for u in uris]}
print(json.dumps(payload))
" "${uris[@]}")

  local response_file
  response_file=$(mktemp)

  local http_code
  http_code=$(curl -sS -o "$response_file" -w "%{http_code}" \
    -X PATCH "${AURL}/api/v3/providers/oauth2/${id}/" \
    -H "Authorization: Bearer ${ATOK}" \
    -H "Content-Type: application/json" \
    -d "$payload")

  if [[ "$http_code" == "200" ]]; then
    echo "OK: ${name} (id=${id}): redirect_uris set to: ${uris[*]}"
  else
    echo "ERROR: ${name} (id=${id}): HTTP ${http_code}" >&2
    cat "$response_file" >&2
    rm -f "$response_file"
    return 1
  fi

  rm -f "$response_file"
}

echo "Patching redirect URIs for all registered providers..."
echo ""

patch_provider "ArgoCD"      "https://demo-argocd.${D}/auth/callback"
patch_provider "Forgejo"     "https://forgejo.${D}/user/oauth2/authentik/callback"
patch_provider "Gatus"       "https://gatus.${D}/oauth2/callback"
patch_provider "Headlamp"    "https://headlamp.${D}/oidc/callback" "https://k8s.${D}/oidc/callback"
patch_provider "Homepage"    "https://homepage.${D}/api/auth/callback/homepage-oidc"
patch_provider "Homebox"     "https://homebox.${D}/api/v1/users/login/oidc/callback"
patch_provider "Longhorn"    "https://storage.${D}/oauth2/callback"
patch_provider "SemaphoreUI" "https://demo-semaphore.${D}/api/auth/oidc/redirect"
patch_provider "Termix"      "https://demo-termix.${D}/users/oidc/callback"

echo ""
echo "Done. Provider IDs were resolved dynamically from Authentik before patching."
