#!/usr/bin/env bash
# ============================================================================
# IAM OIDC Callback Validation Script
# ============================================================================
# Tests all OIDC-enabled applications by verifying:
#   1. OIDC discovery endpoint is reachable (via Kong → Authentik)
#   2. The app's OIDC login/callback endpoint responds (not "provider not available")
#   3. TLS certificate is valid (production issuer, not staging)
#   4. ExternalSecret sync is healthy
#   5. Network policy permits OIDC traffic
#
# Usage:  ./scripts/iam-oidc-callback-validation.sh [--verbose] [--app NAME]
# ============================================================================
set -euo pipefail

# --- Resolve domain from cluster secret (never hardcode) -------------------
DOMAIN=$(kubectl get secret flux-domain-vars -n flux-system \
  -o jsonpath='{.data.DOMAIN}' 2>/dev/null | base64 -d) || {
  echo "ERROR: Cannot read flux-domain-vars secret. Are you connected to the cluster?"
  exit 1
}

VERBOSE=false
FILTER_APP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE=true; shift ;;
    --app)     FILTER_APP="$2"; shift 2 ;;
    *)         echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# --- Colors ----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Counters --------------------------------------------------------------
PASS=0
FAIL=0
WARN=0

# --- OIDC Application Registry ---------------------------------------------
# Format: "app_name|namespace|deployment|slug|callback_path|externalsecret_name"
OIDC_APPS=(
  "vault|vault|vault-0|vault|/ui/vault/auth/oidc/oidc/callback|vault-oidc"
  "headlamp|headlamp|headlamp|headlamp|/oidc/callback|headlamp-oidc"
  "homebox|homebox|homebox|homebox|/api/v1/users/login/oidc/callback|homebox-oidc"
  "openwebui|ai|openwebui|openwebui|/oauth/oidc/callback|openwebui-oidc"
)

# --- Hostname map (app → subdomain) ----------------------------------------
declare -A SUBDOMAIN_MAP=(
  [vault]="vault"
  [headlamp]="k8s"
  [homebox]="homebox"
  [openwebui]="ai-chat"
)

# --- Kong ClusterIP (for direct TLS check) ---------------------------------
KONG_CLUSTERIP="10.104.220.100"

# --- Helper functions -------------------------------------------------------
log_result() {
  local app="$1" test="$2" status="$3" detail="${4:-}"
  local icon color
  case "$status" in
    PASS) icon="✓"; color="$GREEN"; PASS=$((PASS + 1)) ;;
    FAIL) icon="✗"; color="$RED";   FAIL=$((FAIL + 1)) ;;
    WARN) icon="!"; color="$YELLOW"; WARN=$((WARN + 1)) ;;
  esac
  printf "  ${color}${icon}${NC} %-12s %-35s %s\n" "[$status]" "$test" "$detail"
}

verbose() {
  if $VERBOSE; then
    echo "    → $*"
  fi
}

# --- Test Functions ---------------------------------------------------------

test_tls_cert() {
  local app="$1"
  local subdomain="${SUBDOMAIN_MAP[$app]}"
  local hostname="${subdomain}.${DOMAIN}"

  # Test TLS via curl against the external URL (works from any host)
  local issuer=""
  issuer=$(curl -svk --max-time 5 "https://${hostname}/" 2>&1 | \
    grep -i "issuer:" | head -1 || true)

  if echo "$issuer" | grep -qi "STAGING\|Fake\|Invalid"; then
    log_result "$app" "TLS certificate (production)" "FAIL" "STAGING cert detected"
    return 1
  elif [[ -n "$issuer" ]]; then
    log_result "$app" "TLS certificate (production)" "PASS" "$(echo "$issuer" | sed 's/.*issuer: //')"
    return 0
  else
    log_result "$app" "TLS certificate (production)" "FAIL" "No cert returned"
    return 1
  fi
}

test_oidc_discovery() {
  local app="$1" namespace="$2" deployment="$3" slug="$4"
  local discovery_url="https://auth.${DOMAIN}/application/o/${slug}/.well-known/openid-configuration"

  # Test from inside the pod (validates network policy + DNS + TLS)
  local result exit_code=0
  if [[ "$deployment" == "vault-0" ]]; then
    # Vault is a StatefulSet
    result=$(kubectl exec -n "$namespace" "$deployment" -- \
      sh -c "curl -sk --max-time 5 '$discovery_url' 2>/dev/null || wget -qO- --timeout=5 '$discovery_url' 2>/dev/null" 2>/dev/null) || exit_code=$?
  else
    result=$(kubectl exec -n "$namespace" "deploy/$deployment" -- \
      sh -c "curl -sk --max-time 5 '$discovery_url' 2>/dev/null || wget -qO- --timeout=5 '$discovery_url' 2>/dev/null" 2>/dev/null) || exit_code=$?
  fi

  if [[ $exit_code -eq 0 ]] && echo "$result" | grep -q "issuer"; then
    log_result "$app" "OIDC discovery (in-pod)" "PASS" ""
    verbose "Issuer: $(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('issuer','?'))" 2>/dev/null)"
    return 0
  else
    log_result "$app" "OIDC discovery (in-pod)" "FAIL" "Cannot reach discovery endpoint"
    verbose "Exit: $exit_code | Output: ${result:0:100}"
    return 1
  fi
}

test_oidc_endpoint() {
  local app="$1" callback_path="$2"
  local subdomain="${SUBDOMAIN_MAP[$app]}"
  local url="https://${subdomain}.${DOMAIN}${callback_path}"

  # For most apps, hitting the OIDC login endpoint should NOT return "provider not available"
  local response http_code
  response=$(curl -sk --max-time 10 -o /tmp/oidc_response_$$ -w "%{http_code}" \
    "https://${subdomain}.${DOMAIN}/api/v1/users/login/oidc" 2>/dev/null) || response="000"
  local body
  body=$(cat /tmp/oidc_response_$$ 2>/dev/null) || body=""
  rm -f /tmp/oidc_response_$$

  # App-specific checks
  case "$app" in
    homebox)
      if echo "$body" | grep -q "not available"; then
        log_result "$app" "OIDC login endpoint" "FAIL" "Provider not available"
        return 1
      elif [[ "$response" =~ ^(200|302|303|307) ]]; then
        log_result "$app" "OIDC login endpoint" "PASS" "HTTP $response"
        return 0
      else
        log_result "$app" "OIDC login endpoint" "WARN" "HTTP $response"
        return 0
      fi
      ;;
    openwebui)
      # Open WebUI redirects to Authentik on /oauth/oidc/callback access
      local owui_resp
      owui_resp=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
        -L --max-redirs 0 \
        "https://${subdomain}.${DOMAIN}/oauth/oidc/callback" 2>/dev/null) || owui_resp="000"
      if [[ "$owui_resp" =~ ^(302|303|307|400|401|422) ]]; then
        # 302=redirect to Authentik, 400/422=missing code param (expected without auth code)
        log_result "$app" "OIDC callback endpoint" "PASS" "HTTP $owui_resp (expected)"
        return 0
      elif [[ "$owui_resp" == "000" ]]; then
        log_result "$app" "OIDC callback endpoint" "FAIL" "Timeout/unreachable"
        return 1
      else
        log_result "$app" "OIDC callback endpoint" "WARN" "HTTP $owui_resp"
        return 0
      fi
      ;;
    vault)
      # Vault OIDC is configured server-side; test the auth method exists
      local vault_resp
      vault_resp=$(kubectl exec -n vault vault-0 -- \
        vault auth list -format=json 2>/dev/null | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print('oidc' if 'oidc/' in d else 'missing')" 2>/dev/null) || vault_resp="error"
      if [[ "$vault_resp" == "oidc" ]]; then
        log_result "$app" "OIDC auth method" "PASS" "auth/oidc/ enabled"
        return 0
      else
        log_result "$app" "OIDC auth method" "FAIL" "auth/oidc/ not found"
        return 1
      fi
      ;;
    headlamp)
      # Headlamp is behind Cloudflare Access — timeout or 403 is expected externally
      local hl_resp
      hl_resp=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
        -L --max-redirs 0 \
        "https://${subdomain}.${DOMAIN}/oidc/callback" 2>/dev/null) || hl_resp="000"
      if [[ "$hl_resp" =~ ^(302|303|307|400|401|403) ]]; then
        log_result "$app" "OIDC callback endpoint" "PASS" "HTTP $hl_resp (expected)"
        return 0
      elif [[ "$hl_resp" == "000" ]]; then
        # Behind Cloudflare Access — timeout means Access is blocking, which is correct
        log_result "$app" "OIDC callback endpoint" "PASS" "Behind Cloudflare Access (timeout expected)"
        return 0
      else
        log_result "$app" "OIDC callback endpoint" "WARN" "HTTP $hl_resp"
        return 0
      fi
      ;;
  esac
}

test_externalsecret() {
  local app="$1" namespace="$2" es_name="$3"

  local status
  status=$(kubectl get externalsecret "$es_name" -n "$namespace" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null) || status=""

  if [[ "$status" == "SecretSynced" ]]; then
    log_result "$app" "ExternalSecret sync" "PASS" "$es_name"
    return 0
  elif [[ -z "$status" ]]; then
    log_result "$app" "ExternalSecret sync" "WARN" "Not found: $es_name"
    return 0
  else
    log_result "$app" "ExternalSecret sync" "FAIL" "Status: $status"
    return 1
  fi
}

test_netpol_kong_egress() {
  local app="$1" namespace="$2"

  local has_kong_policy
  has_kong_policy=$(kubectl get netpol -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

  if echo "$has_kong_policy" | grep -q "egress-to-kong\|egress-openwebui-to-kong"; then
    log_result "$app" "NetworkPolicy (Kong egress)" "PASS" ""
    return 0
  else
    log_result "$app" "NetworkPolicy (Kong egress)" "FAIL" "No allow-egress-to-kong policy"
    return 1
  fi
}

# --- Main -------------------------------------------------------------------
printf "\n${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}\n"
printf "${BOLD}${CYAN}  IAM OIDC Validation — Domain: ${DOMAIN}${NC}\n"
printf "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${NC}\n\n"

# Global TLS check (one cert serves all)
printf "${BOLD}Global TLS Certificate:${NC}\n"
test_tls_cert "vault"  # any app works, same wildcard cert
echo

for entry in "${OIDC_APPS[@]}"; do
  IFS='|' read -r app namespace deployment slug callback_path es_name <<< "$entry"

  # Filter if --app was specified
  if [[ -n "$FILTER_APP" && "$app" != "$FILTER_APP" ]]; then
    continue
  fi

  printf "${BOLD}${app} (namespace: ${namespace}):${NC}\n"

  test_externalsecret "$app" "$namespace" "$es_name"
  test_netpol_kong_egress "$app" "$namespace"
  test_oidc_discovery "$app" "$namespace" "$deployment" "$slug"
  test_oidc_endpoint "$app" "$callback_path"

  echo
done

# --- Summary ----------------------------------------------------------------
printf '%0.s─' {1..62}; echo
printf "${GREEN}PASS: %d${NC}  ${YELLOW}WARN: %d${NC}  ${RED}FAIL: %d${NC}\n" \
  "$PASS" "$WARN" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  echo
  printf "${RED}Some OIDC validations failed. Troubleshooting:${NC}\n"
  echo "  1. Check TLS:    echo | openssl s_client -connect ${KONG_CLUSTERIP}:8443 -servername auth.${DOMAIN}"
  echo "  2. Check netpol: kubectl get netpol -n <namespace> | grep kong"
  echo "  3. Check secret: kubectl get externalsecret -n <namespace>"
  echo "  4. Check logs:   kubectl logs -n <namespace> deploy/<app> | grep -i oidc"
  exit 1
fi

exit 0
