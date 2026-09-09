#!/usr/bin/env bash
# scripts/lifecycle/validate-control-tower.sh
# Positive + negative validation matrix for the Wave -1c/-1d SSH/Ansible/Semaphore/Vault
# control tower. Modeled on scripts/zero-trust-validate.sh (ephemeral in-cluster test pods
# for anything that must be proven from Semaphore's own network position).
#
# Usage:
#   ./scripts/lifecycle/validate-control-tower.sh [--quick] [--node <hostname>]
#
# Requirements (each check SKIPs cleanly, rather than failing, if its prerequisite is absent):
#   - kubectl context pointing at the live cluster            (cluster-level checks)
#   - VAULT_TOKEN exported in this shell                       (Vault CA/role checks)
#   - CONTROL_TOWER_SSH_PRIVATE_KEY / CONTROL_TOWER_SSH_CERTIFICATE env vars pointing at an
#     already-issued ephemeral Vault certificate                (node-level Ansible checks)
#
# Never prints credentials, private keys, certificates, or tokens.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ANSIBLE_DIR="$REPO_ROOT/automation/ansible"

IMAGE="semaphoreui/semaphore:v2.19.8"   # same image/tooling Semaphore itself uses
TIMEOUT_ALLOW=8
TIMEOUT_DENY=5
QUICK=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true; shift ;;
    --node)  NODE_FILTER="$2"; shift 2 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

PASS=0; FAIL=0; SKIP=0
RESULTS=()

record() {
  local status="$1" desc="$2" icon
  case "$status" in
    PASS) icon="${GREEN}✓${NC}"; PASS=$((PASS + 1)) ;;
    FAIL) icon="${RED}✗${NC}"; FAIL=$((FAIL + 1)) ;;
    SKIP) icon="${YELLOW}⊘${NC}"; SKIP=$((SKIP + 1)) ;;
  esac
  RESULTS+=("$(printf " %b  %-6s  %s" "$icon" "$status" "$desc")")
}

flush() { for r in "${RESULTS[@]}"; do echo -e "$r"; done; RESULTS=(); }

section() {
  echo -e "${BOLD:-}${CYAN}── $1 ──────────────────────────────────────────${NC}"
}

# in_cluster_test <desc> <expect:allow|deny> <shell-command> — ephemeral pod running as the
# semaphore-ansible ServiceAccount, proving the same network position Semaphore itself has.
in_cluster_test() {
  local desc="$1" expect="$2" cmd="$3" timeout exit_code=0
  if [[ "$expect" == "allow" ]]; then timeout=$TIMEOUT_ALLOW; else timeout=$TIMEOUT_DENY; fi
  kubectl run "ct-test-$$" -n "$SEMAPHORE_NAMESPACE" --rm -i --restart=Never \
    --image="$IMAGE" --timeout="${timeout}0s" \
    --overrides="{\"spec\":{\"serviceAccountName\":\"semaphore-ansible\",\"terminationGracePeriodSeconds\":1}}" \
    --command -- sh -c "timeout $timeout $cmd" &>/dev/null || exit_code=$?
  kubectl delete pod "ct-test-$$" -n "$SEMAPHORE_NAMESPACE" --ignore-not-found --grace-period=0 --force &>/dev/null || true
  if { [[ "$expect" == "allow" && $exit_code -eq 0 ]] || [[ "$expect" == "deny" && $exit_code -ne 0 ]]; }; then
    record PASS "$desc"
  else
    record FAIL "$desc"
  fi
}

echo -e "${CYAN}Wave -1c/-1d control-tower validation${NC}  $(date '+%Y-%m-%d %H:%M:%S')"

# ─── pre-flight ────────────────────────────────────────────────────────────────
require_cmd kubectl
require_cmd jq
require_cmd ssh-keygen
if ! kubectl cluster-info &>/dev/null; then
  fail "Cannot connect to cluster"
fi

# ═══════════════════════════════════════════════════════════════════════════════
section "Vault SSH CA / signing role (requires VAULT_TOKEN)"
if [[ -z "${VAULT_TOKEN:-}" ]]; then
  record SKIP "Vault SSH CA exists (VAULT_TOKEN not exported)"
  record SKIP "Vault signing role homelab-ansible exists (VAULT_TOKEN not exported)"
else
  VAULT_POD=$(vault_pod_name)
  if kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
      env VAULT_TOKEN="$VAULT_TOKEN" vault read "$VAULT_SSH_MOUNT/config/ca" &>/dev/null; then
    record PASS "Vault SSH CA exists at $VAULT_SSH_MOUNT/config/ca"
  else
    record FAIL "Vault SSH CA exists at $VAULT_SSH_MOUNT/config/ca"
  fi

  if ROLE_JSON=$(kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
      env VAULT_TOKEN="$VAULT_TOKEN" vault read -format=json "$VAULT_SSH_MOUNT/roles/$VAULT_SSH_ROLE" 2>/dev/null); then
    record PASS "Vault signing role $VAULT_SSH_ROLE exists"
    MAX_TTL=$(echo "$ROLE_JSON" | jq -r '.data.max_ttl')
    ALLOWED_USERS=$(echo "$ROLE_JSON" | jq -r '.data.allowed_users')
    [[ "$MAX_TTL" -le 3600 ]] 2>/dev/null && record PASS "Signing role max_ttl <= 60m ($MAX_TTL s)" \
      || record FAIL "Signing role max_ttl <= 60m (got $MAX_TTL s)"
    [[ "$ALLOWED_USERS" == "ansible" ]] && record PASS "Signing role allowed_users == ansible" \
      || record FAIL "Signing role allowed_users == ansible (got $ALLOWED_USERS)"
  else
    record FAIL "Vault signing role $VAULT_SSH_ROLE exists"
  fi
fi
flush

# ═══════════════════════════════════════════════════════════════════════════════
section "Semaphore -> Vault Kubernetes auth"
if kubectl get serviceaccount semaphore-ansible -n "$SEMAPHORE_NAMESPACE" &>/dev/null; then
  record PASS "ServiceAccount semaphore-ansible exists in $SEMAPHORE_NAMESPACE"
else
  record SKIP "ServiceAccount semaphore-ansible exists (Flux has not reconciled yet)"
fi

if $QUICK; then
  record SKIP "Semaphore Kubernetes-auth login to Vault succeeds (--quick)"
else
  in_cluster_test "Semaphore Kubernetes-auth login to Vault succeeds" allow \
    'curl -sf -X POST --data "{\"jwt\":\"$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\",\"role\":\"semaphore-ansible\"}" http://vault.vault.svc.cluster.local:8200/v1/auth/kubernetes/login | grep -q client_token'
fi
flush

# ═══════════════════════════════════════════════════════════════════════════════
section "Network reachability (mirrors NetworkPolicy intent)"
for entry in "${CONTROL_TOWER_NODES[@]}"; do
  name="${entry%%:*}"; ip="${entry##*:}"
  if $QUICK; then
    record SKIP "Semaphore -> $name ($ip:22) reachable (--quick)"
    continue
  fi
  in_cluster_test "Semaphore -> $name ($ip:22) reachable" allow "nc -z -w $TIMEOUT_ALLOW $ip 22"
done
if ! $QUICK; then
  in_cluster_test "Semaphore -> Vault ($VAULT_NAMESPACE:8200) reachable" allow \
    "nc -z -w $TIMEOUT_ALLOW vault.vault.svc.cluster.local 8200"
  in_cluster_test "Semaphore cannot reach arbitrary RFC1918 host outside declared node /32s" deny \
    "nc -z -w $TIMEOUT_DENY 172.16.20.199 22"
fi
flush

# ═══════════════════════════════════════════════════════════════════════════════
section "Node-level checks (requires an already-issued ephemeral certificate)"
if [[ -z "${CONTROL_TOWER_SSH_PRIVATE_KEY:-}" || -z "${CONTROL_TOWER_SSH_CERTIFICATE:-}" ]]; then
  record SKIP "ansible user / sudo / sshd -t / admin break-glass / ping+raw (no ephemeral cert supplied)"
  flush
else
  ANSIBLE_LIMIT=()
  [[ -n "${NODE_FILTER:-}" ]] && ANSIBLE_LIMIT=(--limit "$NODE_FILTER")
  if (cd "$ANSIBLE_DIR" && ansible-playbook playbooks/90-control-tower-validation.yml \
      -e "control_tower_ssh_private_key=${CONTROL_TOWER_SSH_PRIVATE_KEY}" \
      -e "control_tower_ssh_certificate=${CONTROL_TOWER_SSH_CERTIFICATE}" \
      "${ANSIBLE_LIMIT[@]}" &>/dev/null); then
    record PASS "automation/ansible/playbooks/90-control-tower-validation.yml (all nodes)"
  else
    record FAIL "automation/ansible/playbooks/90-control-tower-validation.yml (all nodes)"
  fi
  flush
fi

# ═══════════════════════════════════════════════════════════════════════════════
section "Negative security tests (run directly against nodes, no cluster needed)"
if $QUICK; then
  record SKIP "Negative SSH tests (--quick)"
else
  NEGATIVE_WORKDIR=$(create_ephemeral_ssh_workdir)
  ssh-keygen -q -t ed25519 -N '' -f "$NEGATIVE_WORKDIR/unsigned_key" </dev/null

  for entry in "${CONTROL_TOWER_NODES[@]}"; do
    ip="${entry##*:}"

    ssh -o BatchMode=no -o PreferredAuthentications=password -o PasswordAuthentication=yes \
        -o ConnectTimeout="$TIMEOUT_DENY" -o StrictHostKeyChecking=yes \
        ansible@"$ip" true &>/dev/null \
      && record FAIL "ansible@$ip rejects password auth" \
      || record PASS "ansible@$ip rejects password auth"

    ssh -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityFile="$NEGATIVE_WORKDIR/unsigned_key" \
        -o ConnectTimeout="$TIMEOUT_DENY" -o StrictHostKeyChecking=yes \
        ansible@"$ip" true &>/dev/null \
      && record FAIL "ansible@$ip rejects an unsigned arbitrary key" \
      || record PASS "ansible@$ip rejects an unsigned arbitrary key"

    ssh -o BatchMode=yes -o ConnectTimeout="$TIMEOUT_DENY" -o StrictHostKeyChecking=yes \
        root@"$ip" true &>/dev/null \
      && record FAIL "root@$ip SSH remains disabled" \
      || record PASS "root@$ip SSH remains disabled"
  done

  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    VAULT_POD=$(vault_pod_name)
    ssh-keygen -q -t ed25519 -N '' -f "$NEGATIVE_WORKDIR/wrong_principal_key" </dev/null
    WRONG_PRINCIPAL_PUB=$(cat "$NEGATIVE_WORKDIR/wrong_principal_key.pub")
    if SIGNED=$(kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
        env VAULT_TOKEN="$VAULT_TOKEN" vault write -field=signed_key "$VAULT_SSH_MOUNT/sign/$VAULT_SSH_ROLE" \
        public_key="$WRONG_PRINCIPAL_PUB" valid_principals=nonexistent-principal 2>/dev/null); then
      echo "$SIGNED" > "$NEGATIVE_WORKDIR/wrong_principal_key-cert.pub"
      for entry in "${CONTROL_TOWER_NODES[@]}"; do
        ip="${entry##*:}"
        ssh -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityFile="$NEGATIVE_WORKDIR/wrong_principal_key" \
            -o CertificateFile="$NEGATIVE_WORKDIR/wrong_principal_key-cert.pub" \
            -o ConnectTimeout="$TIMEOUT_DENY" -o StrictHostKeyChecking=yes \
            ansible@"$ip" true &>/dev/null \
          && record FAIL "ansible@$ip rejects a wrong-principal Vault certificate" \
          || record PASS "ansible@$ip rejects a wrong-principal Vault certificate"
      done
    else
      record SKIP "wrong-principal Vault certificate test (signing request failed)"
    fi
  else
    record SKIP "wrong-principal Vault certificate test (VAULT_TOKEN not exported)"
  fi
fi
flush

echo -e "${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}SKIP: $SKIP${NC}  TOTAL: $((PASS + FAIL + SKIP))"
[[ $FAIL -eq 0 ]]
