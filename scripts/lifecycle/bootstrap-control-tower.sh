#!/usr/bin/env bash
# scripts/lifecycle/bootstrap-control-tower.sh
# Idempotent orchestrator for Wave -1c: activates the Ansible/Semaphore/Vault SSH control
# tower. Intended to be launched from the owner's VS Code WSL shell.
#
# Usage:
#   ./scripts/lifecycle/bootstrap-control-tower.sh <stage> [--dry-run] [--node <hostname>] [--verbose]
#
# Stages:
#   preflight   read-only drift checks (safe to run any time)
#   vault-ca    configure Vault as the SSH client CA + signing role + Semaphore K8s-auth role
#   nodes       create the `ansible` account + install Vault CA trust (admin/wheel route)
#   semaphore   verify the Semaphore ServiceAccount/Vault wiring reconciled via Flux
#   validate    run the full positive/negative control-tower validation matrix
#   all         run every stage above in order, with a confirmation gate before each
#
# Requirements:
#   - kubectl context pointing at the live cluster
#   - ansible-playbook + collections from automation/ansible/requirements.yml
#   - VAULT_TOKEN exported in this shell for the vault-ca and nodes stages (never stored)
#
# This script never uses sshpass. The one-time node bootstrap route relies on the operator's
# own interactive admin SSH/sudo access (SSH agent key and/or an interactive sudo password
# prompt via `-K`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ANSIBLE_DIR="$REPO_ROOT/automation/ansible"

STAGE=""
EXTRA_ANSIBLE_ARGS=()

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# ─── argument parsing ──────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage
STAGE="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --node)    NODE_FILTER="$2"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

if [[ -n "$NODE_FILTER" ]]; then
  EXTRA_ANSIBLE_ARGS+=(--limit "$NODE_FILTER")
fi
if [[ "$DRY_RUN" == "true" ]]; then
  EXTRA_ANSIBLE_ARGS+=(--check --diff)
fi
if [[ "$VERBOSE" == "true" ]]; then
  EXTRA_ANSIBLE_ARGS+=(-v)
fi

require_cmd kubectl
require_cmd ansible-playbook
require_cmd jq

run_playbook() {
  local playbook="$1"; shift
  (cd "$ANSIBLE_DIR" && ansible-playbook "playbooks/$playbook" "${EXTRA_ANSIBLE_ARGS[@]}" "$@")
}

# ─── stages ─────────────────────────────────────────────────────────────────────
stage_preflight() {
  info "Running read-only control-tower preflight checks..."
  info "(admin/wheel route: you will be prompted for the SSH login password, then the sudo/become password)"
  run_playbook 00-control-tower-preflight.yml -k -K
  run_playbook 01-control-tower-smoke-test.yml -k -K
  ok "Preflight complete"
}

stage_vault_ca() {
  [[ -n "${VAULT_TOKEN:-}" ]] || fail "Export VAULT_TOKEN in this shell first (never stored on disk)."
  confirm "This will configure Vault's SSH secrets engine (CA, signing role, policy, K8s-auth role) on the LIVE cluster. Continue?" \
    || fail "Aborted by operator."
  info "Configuring Vault as the homelab SSH client CA..."
  run_playbook 05-control-tower-vault-ca.yml
  ok "Vault SSH CA + signing role + Semaphore Kubernetes-auth role configured"
}

stage_nodes() {
  [[ -n "${VAULT_TOKEN:-}" ]] || fail "Export VAULT_TOKEN in this shell first (never stored on disk)."
  confirm "This will create the 'ansible' account and install the Vault CA trust anchor on LIVE nodes over the admin/wheel route. Continue?" \
    || fail "Aborted by operator."

  info "Fetching the Vault SSH CA public key (public key only — never the private key)..."
  local vault_pod ca_pub ca_extra_vars
  vault_pod=$(vault_pod_name)
  ca_pub=$(kubectl exec -n "$VAULT_NAMESPACE" "$vault_pod" -- \
    env VAULT_TOKEN="$VAULT_TOKEN" vault read -field=public_key "$VAULT_SSH_MOUNT/config/ca")
  [[ -n "$ca_pub" ]] || fail "Could not read the Vault SSH CA public key. Has 'vault-ca' been run yet?"

  # An OpenSSH public key contains spaces (for example: "ssh-rsa AAAA..."). Passing it as a
  # plain Ansible key=value extra-var lets Ansible's argument parser split/truncate the value.
  # Encode it as JSON so the complete public key reaches the role byte-for-byte.
  ca_extra_vars=$(jq -cn --arg ca "$ca_pub" '{vault_ssh_ca_public_key:$ca}')

  info "Applying node changes one at a time (never sshpass; interactive admin SSH/sudo as needed)..."
  run_playbook 10-control-tower-ssh-accounts.yml --extra-vars "$ca_extra_vars" -k -K
  ok "Node SSH trust + ansible account bootstrap complete"
}

stage_semaphore() {
  info "Verifying the Semaphore ServiceAccount reconciled via Flux..."
  if ! kubectl get serviceaccount semaphore-ansible -n "$SEMAPHORE_NAMESPACE" &>/dev/null; then
    fail "ServiceAccount semaphore-ansible not found in $SEMAPHORE_NAMESPACE yet. Push the HelmRelease change and wait for Flux to reconcile."
  fi
  ok "ServiceAccount semaphore-ansible exists in $SEMAPHORE_NAMESPACE"

  info "Verifying the Semaphore -> Vault NetworkPolicy egress rule exists..."
  kubectl get networkpolicy allow-egress-vault -n "$SEMAPHORE_NAMESPACE" &>/dev/null \
    || fail "NetworkPolicy allow-egress-vault not found in $SEMAPHORE_NAMESPACE."
  ok "NetworkPolicy allow-egress-vault present"

  warn "Remaining manual step: create the Semaphore task template(s) that generate an ephemeral"
  warn "Ed25519 keypair, authenticate to Vault via Kubernetes auth (role semaphore-ansible), sign"
  warn "it through ssh-client-signer/sign/homelab-ansible, run Ansible, then destroy the"
  warn "key/certificate/token. See docs/lifecycle/wave-minus1-control-tower.md."
}

stage_validate() {
  info "Running the full control-tower validation matrix..."
  "$SCRIPT_DIR/validate-control-tower.sh"
}

stage_all() {
  stage_preflight
  stage_vault_ca
  stage_nodes
  stage_semaphore
  stage_validate
}

case "$STAGE" in
  preflight) stage_preflight ;;
  vault-ca)  stage_vault_ca ;;
  nodes)     stage_nodes ;;
  semaphore) stage_semaphore ;;
  validate)  stage_validate ;;
  all)       stage_all ;;
  *) usage ;;
esac
