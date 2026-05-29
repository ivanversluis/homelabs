#!/usr/bin/env bash
# test-tunnel-endpoints.sh — Test all Cloudflare-published applications
# Usage: bash test-tunnel-endpoints.sh [--verbose]

set -euo pipefail

# --- Resolve domain from cluster secret (never hardcode) -------------------
DOMAIN=$(kubectl get secret flux-domain-vars -n flux-system \
  -o jsonpath='{.data.DOMAIN}' 2>/dev/null | base64 -d) || {
  echo "ERROR: Cannot read flux-domain-vars secret. Are you connected to the cluster?"
  exit 1
}

VERBOSE=false
[[ "${1:-}" == "--verbose" ]] && VERBOSE=true

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

TIMEOUT=10
PASS=0
FAIL=0
WARN=0

# Format: "Label|subdomain[/path]"
# Full URL is constructed as: https://<subdomain>.${DOMAIN}[/path]
ENDPOINTS=(
  "ArgoCD|demo-argocd"
  "FM Dev|demo-fm-dev"
  "FM Staging|demo-fm-staging"
  "FM Prod|demo-fm-prod"
  "Vault|demo-vault"
  "Grafana|grafana"
  "Headlamp|k8s"
  "Longhorn|demo-longhorn"
  "Linkding|bookmarks"
  "Termix|demo-termix"
  "Authentik|auth"
  "SemaphoreUI|demo-semaphoreui"
  "n8n|n8n"
  "Portainer|portainer"
  "Pi-hole|pihole/admin"
  "Forgejo|forgejo"
  "OpenClaw|openclaw"
  "Open WebUI|ai-chat"
  "Homepage|homepage"
  "Homebox|homebox"
)

printf "\n${CYAN}%-20s %-8s %-8s %s${RESET}\n" "Service" "Status" "Time" "Result"
printf '%0.s─' {1..70}; echo

for entry in "${ENDPOINTS[@]}"; do
  label="${entry%%|*}"
  subdomain_path="${entry##*|}"
  url="https://${subdomain_path}.${DOMAIN}"
  # Handle entries with path (e.g., pihole/admin → pihole.domain/admin)
  if [[ "$subdomain_path" == */* ]]; then
    local_sub="${subdomain_path%%/*}"
    local_path="${subdomain_path#*/}"
    url="https://${local_sub}.${DOMAIN}/${local_path}"
  fi

  start=$(date +%s%N)
  response=$(curl -sk \
    --max-time "$TIMEOUT" \
    --write-out "%{http_code}|%{url_effective}" \
    --output /dev/null \
    -L \
    "$url" 2>&1) || true
  end=$(date +%s%N)

  elapsed_ms=$(( (end - start) / 1000000 ))
  http_code="${response%%|*}"

  if [[ -z "$http_code" || "$http_code" == "000" ]]; then
    color="$RED"
    result="TIMEOUT / NO RESPONSE"
    FAIL=$((FAIL+1))
  elif [[ "$http_code" -ge 200 && "$http_code" -lt 400 ]]; then
    color="$GREEN"
    result="OK"
    PASS=$((PASS+1))
  elif [[ "$http_code" -ge 400 && "$http_code" -lt 500 ]]; then
    # 401/403 means the app IS reachable (auth wall) — count as reachable
    color="$YELLOW"
    result="AUTH REQUIRED (${http_code})"
    WARN=$((WARN+1))
  else
    color="$RED"
    result="ERROR (${http_code})"
    FAIL=$((FAIL+1))
  fi

  printf "${color}%-20s %-8s %-8s %s${RESET}\n" \
    "${label:0:19}" "$http_code" "${elapsed_ms}ms" "$result"

  if $VERBOSE; then
    echo "  → $url"
  fi
done

echo
printf '%0.s─' {1..70}; echo
printf "${GREEN}PASS: %d${RESET}  ${YELLOW}WARN (auth): %d${RESET}  ${RED}FAIL: %d${RESET}\n" \
  "$PASS" "$WARN" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  echo
  echo "Tip: Run the following to check cloudflared logs for a specific service:"
  echo "  kubectl logs -n cloudflared -l app=cloudflare-tunnel --tail=50 | grep -E 'ERR|timeout'"
  echo
  echo "Check NetworkPolicy with:"
  echo "  kubectl get netpol -A | grep -v Longhorn"
fi
