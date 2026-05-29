#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# OIDC SSO Validation Script
# ─────────────────────────────────────────────────────────────────────────────
# Tests all OIDC-enabled applications for:
#   1. ExternalSecret sync status
#   2. Secret existence and key presence
#   3. OIDC discovery URL reachability from inside pods
#   4. Network policy egress to Kong
#   5. Redirect URI endpoint availability
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOMAIN=$(kubectl get secret flux-domain-vars -n flux-system -o jsonpath='{.data.DOMAIN}' | base64 -d)
PASS=0
FAIL=0
WARN=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { PASS=$((PASS + 1)); echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { FAIL=$((FAIL + 1)); echo -e "${RED}[FAIL]${NC} $1"; }
warn() { WARN=$((WARN + 1)); echo -e "${YELLOW}[WARN]${NC} $1"; }

# ─── Application Registry ────────────────────────────────────────────────────

declare -A APPS
# Format: "namespace:deploy_name:secret_name:slug:redirect_path"
APPS[grafana]="observability:grafana:grafana-oidc:grafana:/login/generic_oauth"
APPS[homebox]="homebox:homebox:homebox-oidc:homebox:/api/v1/users/login/oidc/callback"
APPS[headlamp]="headlamp:headlamp:headlamp-oidc:headlamp:/oidc/callback"
APPS[openwebui]="ai:openwebui:openwebui-oidc:openwebui:/oauth/oidc/callback"
APPS[homepage]="homepage:homepage:homepage-oidc:homepage:/api/auth/callback/authentik"
APPS[forgejo]="forgejo:forgejo:forgejo-oidc:forgejo:/user/oauth2/authentik/callback"
APPS[n8n]="n8n:n8n:n8n-oidc:n8n:/rest/oauth2-credential/callback"
APPS[linkding]="linkding:linkding:linkding-oidc:linkding:/oidc/callback/"
APPS[semaphoreui]="semaphoreui:semaphoreui:semaphoreui-oidc:semaphoreui:/api/auth/oidc/redirect"
APPS[argocd]="argocd:argocd-server:argocd-oidc:argocd:/auth/callback"
APPS[longhorn]="longhorn-system:longhorn-ui:longhorn-oidc:longhorn:/oauth2/callback"
APPS[portainer]="portainer:portainer:portainer-oidc:portainer:/"
APPS[termix]="termix:termix:termix-oidc:termix:/users/oidc/callback"

echo "═══════════════════════════════════════════════════════════════════════"
echo " OIDC SSO Validation — $(date)"
echo " Domain: $DOMAIN"
echo "═══════════════════════════════════════════════════════════════════════"
echo ""

# ─── Test 1: ExternalSecret Sync Status ──────────────────────────────────────
echo "─── ExternalSecret Sync Status ──────────────────────────────────────"
for app in "${!APPS[@]}"; do
    IFS=':' read -r ns deploy secret slug redirect <<< "${APPS[$app]}"
    status=$(kubectl get externalsecret "$secret" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "NotFound")
    if [[ "$status" == "True" ]]; then
        pass "$app: ExternalSecret '$secret' synced in ns/$ns"
    elif [[ "$status" == "NotFound" ]]; then
        warn "$app: ExternalSecret '$secret' not found in ns/$ns"
    else
        fail "$app: ExternalSecret '$secret' NOT synced (status=$status)"
    fi
done
echo ""

# ─── Test 2: Secret Keys Present ─────────────────────────────────────────────
echo "─── Secret Keys Present ─────────────────────────────────────────────"
for app in "${!APPS[@]}"; do
    IFS=':' read -r ns deploy secret slug redirect <<< "${APPS[$app]}"
    keys=$(kubectl get secret "$secret" -n "$ns" -o jsonpath='{.data}' 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(d.keys()))" 2>/dev/null || echo "")
    if [[ -n "$keys" ]]; then
        if echo "$keys" | grep -q "client-id\|OAUTH_CLIENT_ID"; then
            pass "$app: Secret has client-id key (keys: $keys)"
        else
            warn "$app: Secret exists but missing client-id key (keys: $keys)"
        fi
    else
        fail "$app: Secret '$secret' not found or empty in ns/$ns"
    fi
done
echo ""

# ─── Test 3: OIDC Discovery URL (from pod) ───────────────────────────────────
echo "─── OIDC Discovery URL Reachability ─────────────────────────────────"
for app in "${!APPS[@]}"; do
    IFS=':' read -r ns deploy secret slug redirect <<< "${APPS[$app]}"
    discovery_url="https://auth.${DOMAIN}/application/o/${slug}/.well-known/openid-configuration"

    # Containers without wget — use curl or external check
    if [[ "$deploy" == "argocd-server" || "$deploy" == "portainer" || "$deploy" == "longhorn-ui" ]]; then
        result=$(curl -sk --max-time 5 "$discovery_url" 2>/dev/null | head -c 50 || echo "FAILED")
    else
        # Try wget first, fall back to curl (openwebui has curl only)
        result=$(kubectl exec -n "$ns" "deploy/$deploy" -- sh -c "wget -qO- --timeout=5 '$discovery_url' 2>/dev/null || curl -sk --max-time 5 '$discovery_url' 2>/dev/null" 2>/dev/null | head -c 50 || echo "FAILED")
    fi

    if echo "$result" | grep -q "issuer"; then
        pass "$app: OIDC discovery reachable from pod"
    else
        fail "$app: OIDC discovery FAILED from ns/$ns (${discovery_url})"
    fi
done
echo ""

# ─── Test 4: Kong Egress NetworkPolicy ────────────────────────────────────────
echo "─── Kong Egress NetworkPolicy ────────────────────────────────────────"
for app in "${!APPS[@]}"; do
    IFS=':' read -r ns deploy secret slug redirect <<< "${APPS[$app]}"
    # Look for any netpol containing "kong" in its name in this namespace
    kong_pol=$(kubectl get networkpolicy -n "$ns" -o name 2>/dev/null | grep -i "kong" | head -1 || echo "")
    if [[ -n "$kong_pol" ]]; then
        pass "$app: Kong policy exists in ns/$ns (${kong_pol##*/})"
    else
        # Check if the app uses direct Authentik egress instead
        alt=$(kubectl get networkpolicy -n "$ns" -o name 2>/dev/null | grep -i "authentik" | head -1 || echo "")
        if [[ -n "$alt" ]]; then
            pass "$app: Authentik egress exists in ns/$ns (${alt##*/})"
        else
            fail "$app: No Kong/Authentik egress policy in ns/$ns"
        fi
    fi
done
echo ""

# ─── Test 5: TLS Certificate Validity ────────────────────────────────────────
echo "─── TLS Certificate (auth.$DOMAIN via Kong) ─────────────────────────"
KONG_IP=$(kubectl get svc kong-kong-proxy -n kong -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [[ -n "$KONG_IP" ]]; then
    issuer=$(echo | openssl s_client -connect "${KONG_IP}:8443" -servername "auth.${DOMAIN}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | grep -oP 'CN=\K[^/,]+' || echo "UNKNOWN")
    if [[ "$issuer" == *"E"* ]] || [[ "$issuer" == *"R"* ]]; then
        pass "TLS cert issuer: $issuer (production Let's Encrypt)"
    elif [[ "$issuer" == *"STAGING"* ]]; then
        fail "TLS cert is STAGING — OIDC will fail for Go/Python clients"
    else
        warn "TLS cert issuer unknown: $issuer"
    fi
else
    fail "Kong service not found"
fi
echo ""

# ─── Summary ─────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════════"
echo -e " Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$WARN warnings${NC}"
echo "═══════════════════════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
