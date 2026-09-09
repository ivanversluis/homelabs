#!/usr/bin/env bash
# scripts/lifecycle/lib/common.sh
# Shared helpers for the Wave -1 control-tower lifecycle scripts. Source, don't execute.
#
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
#
set -euo pipefail

# ─── known cluster state ──────────────────────────────────────────────────────
CONTROL_TOWER_NODES=(
  "k8s-master01:172.16.20.200"
  "k8s-worker01:172.16.20.201"
  "k8s-worker02:172.16.20.202"
  "k8s-worker03:172.16.20.203"
)
VAULT_NAMESPACE="vault"
SEMAPHORE_NAMESPACE="semaphoreui"
VAULT_SSH_MOUNT="ssh-client-signer"
VAULT_SSH_ROLE="homelab-ansible"

# ─── colors / logging ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${CYAN}ℹ️  $*${NC}"; }
ok()    { echo -e "${GREEN}✅ $*${NC}"; }
warn()  { echo -e "${YELLOW}⚠️  $*${NC}"; }
fail()  { echo -e "${RED}❌ $*${NC}" >&2; exit 1; }

require_cmd() { command -v "$1" &>/dev/null || fail "'$1' is required but not found in PATH"; }

# confirm <prompt> — returns 0 only on an explicit "yes"
confirm() {
  local prompt="$1" reply
  read -r -p "$prompt [type 'yes' to continue]: " reply
  [[ "$reply" == "yes" ]]
}

# ─── shared flags (parsed by callers, defaults here) ──────────────────────────
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"
NODE_FILTER="${NODE_FILTER:-}"

# run_step <description> -- <command...>  — respects DRY_RUN, never echoes secrets by itself
run_step() {
  local desc="$1"; shift
  [[ "$1" == "--" ]] && shift
  info "$desc"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [dry-run] $*"
    return 0
  fi
  if [[ "$VERBOSE" == "true" ]]; then
    "$@"
  else
    "$@" >/dev/null
  fi
}

# ─── ephemeral SSH credential lifecycle ───────────────────────────────────────
# create_ephemeral_ssh_workdir — makes a private tmpdir and registers cleanup on EXIT.
# Callers must never write the resulting key/cert/token outside this directory.
create_ephemeral_ssh_workdir() {
  local workdir
  workdir=$(mktemp -d "${TMPDIR:-/tmp}/control-tower.XXXXXX")
  chmod 700 "$workdir"
  # shellcheck disable=SC2064 # intentional early expansion of $workdir
  trap "rm -rf '$workdir'" EXIT
  echo "$workdir"
}

# node_ip <hostname> — looks up an IP from CONTROL_TOWER_NODES
node_ip() {
  local host="$1" entry
  for entry in "${CONTROL_TOWER_NODES[@]}"; do
    if [[ "${entry%%:*}" == "$host" ]]; then
      echo "${entry##*:}"
      return 0
    fi
  done
  return 1
}

# vault_pod_name — resolves the running Vault pod (read-only kubectl call)
vault_pod_name() {
  kubectl get pod -n "$VAULT_NAMESPACE" -l app.kubernetes.io/name=vault \
    -o jsonpath='{.items[0].metadata.name}'
}
