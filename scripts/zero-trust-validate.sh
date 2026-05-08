#!/usr/bin/env bash
# ============================================================================
# Zero Trust Network Policy Validation Script
# ============================================================================
# Tests all network policies in the homelab cluster by running ephemeral pods
# and verifying allowed (happy) and denied (rainy) traffic flows.
#
# Usage:  ./scripts/zero-trust-validate.sh [--quick] [--namespace NS]
#
# --quick       Only test DNS + cross-ns deny (skip internet tests)
# --namespace   Test a single namespace instead of all
# ============================================================================
set -euo pipefail

# --- Configuration ---------------------------------------------------------
IMAGE="nicolaka/netshoot"
TIMEOUT_ALLOW=5         # seconds to wait for allowed connections
TIMEOUT_DENY=3          # seconds to wait for denied connections (should fail)
API_CLUSTERIP="10.96.0.1"
API_NODE="172.16.20.200"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Counters
PASS=0
FAIL=0
SKIP=0
RESULTS=()

QUICK=false
FILTER_NS=""

# --- Argument parsing -------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)    QUICK=true; shift ;;
    --namespace) FILTER_NS="$2"; shift 2 ;;
    *)          echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# --- Helpers ----------------------------------------------------------------
run_test_pod() {
  local ns="$1"; shift
  kubectl run zt-test -n "$ns" --rm -i --restart=Never \
    --image="$IMAGE" --timeout="${TIMEOUT_ALLOW}0s" \
    --override-type=strategic \
    --overrides='{"spec":{"terminationGracePeriodSeconds":1}}' \
    -- "$@" 2>/dev/null
}

# test_conn <namespace> <description> <expect:allow|deny> <args...>
test_conn() {
  local ns="$1" desc="$2" expect="$3"; shift 3
  local timeout
  if [[ "$expect" == "allow" ]]; then
    timeout="$TIMEOUT_ALLOW"
  else
    timeout="$TIMEOUT_DENY"
  fi

  local result exit_code=0
  result=$(kubectl run "zt-test-$$" -n "$ns" --rm -i --restart=Never \
    --image="$IMAGE" --timeout="${timeout}0s" \
    --override-type=strategic \
    --overrides='{"spec":{"terminationGracePeriodSeconds":1}}' \
    -- timeout "$timeout" "$@" 2>&1) || exit_code=$?

  # Clean up pod if stuck
  kubectl delete pod "zt-test-$$" -n "$ns" --ignore-not-found --grace-period=0 --force &>/dev/null || true

  local status icon
  if [[ "$expect" == "allow" ]]; then
    if [[ $exit_code -eq 0 ]]; then
      status="PASS"; icon="${GREEN}✓${NC}"; PASS=$((PASS + 1))
    else
      status="FAIL"; icon="${RED}✗${NC}"; FAIL=$((FAIL + 1))
    fi
  else
    if [[ $exit_code -ne 0 ]]; then
      status="PASS"; icon="${GREEN}✓${NC}"; PASS=$((PASS + 1))
    else
      status="FAIL"; icon="${RED}✗${NC}"; FAIL=$((FAIL + 1))
    fi
  fi

  RESULTS+=("$(printf " %b  %-25s  %-6s  %-45s" "$icon" "$ns" "$expect" "$desc")")
}

# test_dns <namespace>
test_dns() {
  local ns="$1"
  test_conn "$ns" "DNS resolution (kube-dns)" "allow" \
    nslookup -timeout=3 kubernetes.default.svc.cluster.local
}

# test_cross_ns_deny <namespace> — try connecting to a namespace that should be blocked
test_cross_ns_deny() {
  local ns="$1"
  # Try to reach linkding from this ns (unless we ARE linkding)
  local target_ns="linkding" target_port="9090"
  if [[ "$ns" == "linkding" ]]; then
    target_ns="forgejo"; target_port="3000"
  fi
  # Skip if this ns has legitimate access to target
  if [[ "$ns" == "cloudflared" ]]; then
    target_ns="vault"; target_port="8200"
  fi
  test_conn "$ns" "Cross-ns BLOCKED ($target_ns:$target_port)" "deny" \
    nc -z -w "$TIMEOUT_DENY" "$target_ns.$target_ns.svc.cluster.local" "$target_port"
}

# test_internet <namespace> <port> <proto:tcp|udp> <expect>
test_internet() {
  local ns="$1" port="$2" proto="$3" expect="$4"
  if $QUICK; then
    SKIP=$((SKIP + 1))
    RESULTS+=("$(printf " ${YELLOW}⊘${NC}  %-25s  %-6s  %-45s" "$ns" "skip" "Internet $proto/$port (--quick)")")
    return
  fi
  if [[ "$proto" == "tcp" ]]; then
    test_conn "$ns" "Internet egress TCP/$port" "$expect" \
      nc -z -w "$TIMEOUT_ALLOW" 1.1.1.1 "$port"
  else
    test_conn "$ns" "Internet egress UDP/$port" "$expect" \
      nc -z -u -w "$TIMEOUT_ALLOW" 1.1.1.1 "$port"
  fi
}

# test_apiserver <namespace> <expect>
test_apiserver() {
  local ns="$1" expect="$2"
  test_conn "$ns" "API server (ClusterIP:443)" "$expect" \
    nc -z -w "$TIMEOUT_ALLOW" "$API_CLUSTERIP" 443
}

# test_egress_to_ns <from_ns> <to_ns> <port> <expect>
test_egress_to_ns() {
  local from_ns="$1" to_ns="$2" port="$3" expect="$4"
  # Use the service DNS name — assumes a service exists
  test_conn "$from_ns" "Egress to $to_ns:$port" "$expect" \
    nc -z -w "$TIMEOUT_ALLOW" "$(kubectl get svc -n "$to_ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "$to_ns").$to_ns.svc.cluster.local" "$port"
}

# --- Print header -----------------------------------------------------------
print_header() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║            Zero Trust Network Policy Validation Report                         ║${NC}"
  echo -e "${BOLD}║            $(date '+%Y-%m-%d %H:%M:%S')                                                   ║${NC}"
  echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}║  STS  NAMESPACE                 EXPECT  TEST                                   ║${NC}"
  echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════════════╣${NC}"
}

print_section() {
  echo -e "${BOLD}╟──────────────────────────────────────────────────────────────────────────────────╢${NC}"
  echo -e "${BOLD}║  ${CYAN}$1${NC}"
  echo -e "${BOLD}╟──────────────────────────────────────────────────────────────────────────────────╢${NC}"
}

flush_results() {
  for r in "${RESULTS[@]}"; do
    echo -e "║$r"
  done
  RESULTS=()
}

print_footer() {
  echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════════════════════╣${NC}"
  local total=$((PASS + FAIL + SKIP))
  echo -e "${BOLD}║  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}SKIP: $SKIP${NC}  TOTAL: $total"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════════════════════╝${NC}"
}

# --- Pre-flight checks ------------------------------------------------------
echo -e "${CYAN}Running pre-flight checks...${NC}"

# Verify cluster access
if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}Cannot connect to cluster${NC}"
  exit 1
fi

# Verify GlobalNetworkPolicy
GNP_COUNT=$(kubectl get globalnetworkpolicies --no-headers 2>/dev/null | wc -l)
echo -e "  GlobalNetworkPolicies: $GNP_COUNT"

# Count per-namespace policies
TOTAL_NP=0
for ns in linkding n8n termix forgejo identity headlamp cloudflared vault \
          external-secrets-system observability monitoring pihole dns \
          flux-system openclaw semaphoreui portainer; do
  c=$(kubectl get networkpolicies -n "$ns" --no-headers 2>/dev/null | wc -l)
  TOTAL_NP=$((TOTAL_NP + c))
done
echo -e "  Namespace NetworkPolicies: $TOTAL_NP"
echo ""

# --- Run tests per namespace ------------------------------------------------
print_header

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 1. LINKDING — isolated app, no internet, tunnel ingress only
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
test_ns() {
  local ns="$1"
  [[ -n "$FILTER_NS" && "$FILTER_NS" != "$ns" ]] && return

  case "$ns" in
    linkding)
      print_section "linkding — isolated app, no internet"
      test_dns "$ns"
      test_cross_ns_deny "$ns"
      test_internet "$ns" 443 tcp deny
      flush_results
      ;;

    n8n)
      print_section "n8n — webhook engine, internet HTTPS+HTTP"
      test_dns "$ns"
      test_cross_ns_deny "$ns"
      test_internet "$ns" 443 tcp allow
      test_internet "$ns" 80 tcp allow
      test_internet "$ns" 22 tcp deny
      flush_results
      ;;

    termix)
      print_section "termix — SSH client, SSH everywhere"
      test_dns "$ns"
      test_cross_ns_deny "$ns"
      test_internet "$ns" 22 tcp allow
      test_internet "$ns" 443 tcp deny
      flush_results
      ;;

    forgejo)
      print_section "forgejo — git forge, internet HTTPS+SSH"
      test_dns "$ns"
      test_cross_ns_deny "$ns"
      test_internet "$ns" 443 tcp allow
      test_internet "$ns" 22 tcp allow
      test_internet "$ns" 80 tcp deny
      flush_results
      ;;

    identity)
      print_section "identity — Authentik IdP, HTTPS+SMTP"
      test_dns "$ns"
      test_cross_ns_deny "$ns"
      test_internet "$ns" 443 tcp allow
      test_internet "$ns" 587 tcp allow
      test_internet "$ns" 22 tcp deny
      flush_results
      ;;

    headlamp)
      print_section "headlamp — k8s dashboard, API server only"
      test_dns "$ns"
      test_cross_ns_deny "$ns"
      test_apiserver "$ns" allow
      test_internet "$ns" 443 tcp deny
      flush_results
      ;;

    cloudflared)
      print_section "cloudflared — tunnel, edge + proxied services"
      test_dns "$ns"
      test_internet "$ns" 443 tcp allow
      # Deny: should not reach vault directly
      test_conn "$ns" "Cross-ns BLOCKED (vault:8200)" "deny" \
        nc -z -w "$TIMEOUT_DENY" "vault.vault.svc.cluster.local" 8200
      flush_results
      ;;

    vault)
      print_section "vault — secrets, API server + ESO ingress"
      test_dns "$ns"
      test_cross_ns_deny "$ns"
      test_apiserver "$ns" allow
      test_internet "$ns" 443 tcp deny
      flush_results
      ;;

    external-secrets-system)
      print_section "external-secrets — ESO, vault egress + API"
      test_dns "$ns"
      test_cross_ns_deny "$ns"
      test_apiserver "$ns" allow
      # ESO -> Vault
      test_conn "$ns" "Egress to vault:8200" "allow" \
        nc -z -w "$TIMEOUT_ALLOW" "vault-internal.vault.svc.cluster.local" 8200
      test_internet "$ns" 443 tcp deny
      flush_results
      ;;

    observability)
      print_section "observability — Prometheus/Grafana/Loki"
      test_dns "$ns"
      test_cross_ns_deny "$ns"
      test_internet "$ns" 443 tcp deny
      flush_results
      ;;

    monitoring)
      print_section "monitoring — KPS exporters, API server"
      test_dns "$ns"
      test_cross_ns_deny "$ns"
      test_apiserver "$ns" allow
      test_internet "$ns" 443 tcp deny
      flush_results
      ;;

    pihole)
      print_section "pihole — DNS forwarder, unbound + HTTPS"
      test_dns "$ns"
      test_cross_ns_deny "$ns"
      test_internet "$ns" 443 tcp allow
      test_internet "$ns" 22 tcp deny
      flush_results
      ;;

    dns)
      print_section "dns — Unbound recursive resolver"
      test_dns "$ns"
      test_cross_ns_deny "$ns"
      test_internet "$ns" 53 tcp allow
      test_internet "$ns" 443 tcp deny
      flush_results
      ;;

    flux-system)
      print_section "flux-system — GitOps, GitHub + API server"
      test_dns "$ns"
      test_cross_ns_deny "$ns"
      test_apiserver "$ns" allow
      test_internet "$ns" 443 tcp allow
      test_internet "$ns" 22 tcp allow
      test_internet "$ns" 80 tcp deny
      flush_results
      ;;

    openclaw)
      print_section "openclaw — k8s monitor, API + HTTPS"
      test_dns "$ns"
      test_cross_ns_deny "$ns"
      test_apiserver "$ns" allow
      test_internet "$ns" 443 tcp allow
      test_internet "$ns" 22 tcp deny
      flush_results
      ;;

    semaphoreui)
      print_section "semaphoreui — automation, SSH + HTTPS"
      test_dns "$ns"
      test_cross_ns_deny "$ns"
      test_internet "$ns" 443 tcp allow
      test_internet "$ns" 22 tcp allow
      test_internet "$ns" 80 tcp deny
      flush_results
      ;;

    portainer)
      print_section "portainer — container mgmt, API + HTTPS"
      test_dns "$ns"
      test_cross_ns_deny "$ns"
      test_apiserver "$ns" allow
      test_internet "$ns" 443 tcp allow
      test_internet "$ns" 22 tcp deny
      flush_results
      ;;
  esac
}

NAMESPACES=(linkding n8n termix forgejo identity headlamp cloudflared vault \
            external-secrets-system observability monitoring pihole dns \
            flux-system openclaw semaphoreui portainer)

for ns in "${NAMESPACES[@]}"; do
  test_ns "$ns"
done

print_footer

# Exit with failure if any test failed
[[ $FAIL -eq 0 ]]
