#!/usr/bin/env bash
# Run an operational Ansible playbook from Semaphore with a short-lived Vault-signed SSH certificate.
set -Eeuo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://vault.vault.svc.cluster.local:8200}"
VAULT_K8S_ROLE="${VAULT_K8S_ROLE:-semaphore-ansible}"
VAULT_EXPECTED_POLICY="${VAULT_EXPECTED_POLICY:-homelab-ansible-sign}"
VAULT_SSH_MOUNT="${VAULT_SSH_MOUNT:-ssh-client-signer}"
VAULT_SSH_ROLE="${VAULT_SSH_ROLE:-homelab-ansible}"
SSH_PRINCIPAL="${SSH_PRINCIPAL:-ansible}"
SSH_CERT_TTL="${SSH_CERT_TTL:-30m}"
SA_TOKEN_FILE="${SA_TOKEN_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/token}"
CONTROL_TOWER_PLAYBOOK="${CONTROL_TOWER_PLAYBOOK:-playbooks/95-disk-report.yml}"
CONTROL_TOWER_LIMIT="${CONTROL_TOWER_LIMIT:-}"

NODES=(
  "k8s-master01:172.16.20.200"
  "k8s-worker01:172.16.20.201"
  "k8s-worker02:172.16.20.202"
  "k8s-worker03:172.16.20.203"
)

log() { printf '[control-tower] %s\n' "$*"; }
fail() { printf '[control-tower] ERROR: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "required command '$1' is not available in the Semaphore execution environment"; }
trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

log "Starting Semaphore control-tower runner"

for arg in "$@"; do
  case "$arg" in
    playbook=*) CONTROL_TOWER_PLAYBOOK="${arg#playbook=}" ;;
    limit=*) CONTROL_TOWER_LIMIT="${arg#limit=}" ;;
    *=*) log "Ignoring unrelated Semaphore argument: ${arg%%=*}" ;;
    *) log "Ignoring unrelated Semaphore argument without '='" ;;
  esac
done

CONTROL_TOWER_PLAYBOOK="$(trim "$CONTROL_TOWER_PLAYBOOK")"
CONTROL_TOWER_LIMIT="$(trim "$CONTROL_TOWER_LIMIT")"

log "Playbook: [$CONTROL_TOWER_PLAYBOOK]"
log "Target limit: [${CONTROL_TOWER_LIMIT:-all nodes}]"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ANSIBLE_DIR="$REPO_ROOT/automation/ansible"
REPO_KNOWN_HOSTS="$ANSIBLE_DIR/inventories/homelab/known_hosts"

case "$CONTROL_TOWER_PLAYBOOK" in
  playbooks/*.yml|playbooks/*.yaml) ;;
  *) fail "playbook must be a relative path below automation/ansible/playbooks" ;;
esac
[[ "$CONTROL_TOWER_PLAYBOOK" != *".."* ]] || fail "playbook path must not contain '..'"
[[ -f "$ANSIBLE_DIR/$CONTROL_TOWER_PLAYBOOK" ]] || fail "playbook not found: automation/ansible/$CONTROL_TOWER_PLAYBOOK"

# Bootstrap/control-plane configuration must never run through the already-established
# certificate route. These playbooks need privileged local/Vault bootstrap context and can
# mutate the authentication path itself. Run them explicitly from the trusted WSL/admin route.
case "$CONTROL_TOWER_PLAYBOOK" in
  playbooks/05-control-tower-vault-ca.yml|playbooks/10-control-tower-ssh-accounts.yml)
    fail "bootstrap-only playbook '$CONTROL_TOWER_PLAYBOOK' is not allowed through the Semaphore operational runner; use scripts/lifecycle/bootstrap-control-tower.sh from the trusted WSL/admin route"
    ;;
esac

require_cmd ansible-playbook
require_cmd curl
require_cmd python3
require_cmd ssh
require_cmd ssh-keygen
require_cmd mktemp
require_cmd grep

[[ -r "$SA_TOKEN_FILE" ]] || fail "ServiceAccount token is not readable at $SA_TOKEN_FILE; verify Semaphore runs as serviceAccount semaphore-ansible"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/semaphore-control-tower.XXXXXX")"
chmod 700 "$WORKDIR"
VAULT_TOKEN=""
K8S_JWT=""

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ -n "$VAULT_TOKEN" ]]; then
    curl -fsS --max-time 5 -H "X-Vault-Token: $VAULT_TOKEN" -X POST \
      "$VAULT_ADDR/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
  fi
  VAULT_TOKEN=""
  K8S_JWT=""
  rm -rf "$WORKDIR"
  exit "$rc"
}
trap cleanup EXIT INT TERM

KNOWN_HOSTS_FILE="$WORKDIR/known_hosts"
if [[ -n "${CONTROL_TOWER_KNOWN_HOSTS:-}" ]]; then
  printf '%s\n' "$CONTROL_TOWER_KNOWN_HOSTS" > "$KNOWN_HOSTS_FILE"
  log "Using CONTROL_TOWER_KNOWN_HOSTS override from Semaphore"
elif [[ -r "$REPO_KNOWN_HOSTS" ]]; then
  cp "$REPO_KNOWN_HOSTS" "$KNOWN_HOSTS_FILE"
  log "Using repo-pinned host trust: automation/ansible/inventories/homelab/known_hosts"
elif [[ -r "${HOME:-/tmp}/.ssh/known_hosts" ]]; then
  cp "${HOME:-/tmp}/.ssh/known_hosts" "$KNOWN_HOSTS_FILE"
  log "Using existing trusted ${HOME:-/tmp}/.ssh/known_hosts"
else
  fail "no trusted known_hosts is available. Host-key checking will not be bypassed"
fi
chmod 600 "$KNOWN_HOSTS_FILE"

TARGET_NODES=()
case "${CONTROL_TOWER_LIMIT:-}" in
  k8s-master01) TARGET_NODES=("k8s-master01:172.16.20.200") ;;
  k8s-worker01) TARGET_NODES=("k8s-worker01:172.16.20.201") ;;
  k8s-worker02) TARGET_NODES=("k8s-worker02:172.16.20.202") ;;
  k8s-worker03) TARGET_NODES=("k8s-worker03:172.16.20.203") ;;
  workers)
    TARGET_NODES=(
      "k8s-worker01:172.16.20.201"
      "k8s-worker02:172.16.20.202"
      "k8s-worker03:172.16.20.203"
    )
    ;;
  ""|all|k8s_homelab) TARGET_NODES=("${NODES[@]}") ;;
  *)
    log "Limit expression '$CONTROL_TOWER_LIMIT' is not a simple known host/group; requiring trust for all nodes"
    TARGET_NODES=("${NODES[@]}")
    ;;
esac

for entry in "${TARGET_NODES[@]}"; do
  host="${entry%%:*}"
  ip="${entry##*:}"
  ssh-keygen -F "$ip" -f "$KNOWN_HOSTS_FILE" >/dev/null 2>&1 \
    || fail "trusted known_hosts has no entry for $host ($ip); add and independently verify that node's public SSH host key in $REPO_KNOWN_HOSTS"
  log "Trusted host key present for $host ($ip)"
done
log "Host-key preflight passed for ${#TARGET_NODES[@]} target node(s)"

HEALTH_JSON="$(curl -fsS --max-time 8 "$VAULT_ADDR/v1/sys/health?standbyok=true&perfstandbyok=true")" \
  || fail "Vault health endpoint is not reachable from Semaphore"
printf '%s' "$HEALTH_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get("initialized") and not d.get("sealed") else 1)' \
  || fail "Vault is not initialized/unsealed"
log "Vault is reachable and unsealed"

K8S_JWT="$(cat "$SA_TOKEN_FILE")"
LOGIN_PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"role":sys.argv[1],"jwt":sys.stdin.read().strip()}))' "$VAULT_K8S_ROLE" <<<"$K8S_JWT")"
LOGIN_RESPONSE="$(printf '%s' "$LOGIN_PAYLOAD" | curl -fsS --max-time 10 \
  -H 'Content-Type: application/json' --data-binary @- \
  "$VAULT_ADDR/v1/auth/kubernetes/login")" || fail "Vault Kubernetes-auth login failed"
VAULT_TOKEN="$(printf '%s' "$LOGIN_RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("auth",{}).get("client_token",""))')"
[[ -n "$VAULT_TOKEN" ]] || fail "Vault Kubernetes-auth response did not contain a client token"
printf '%s' "$LOGIN_RESPONSE" | python3 -c 'import json,sys; d=json.load(sys.stdin); p=sys.argv[1]; raise SystemExit(0 if p in d.get("auth",{}).get("policies",[]) else 1)' "$VAULT_EXPECTED_POLICY" \
  || fail "Vault token does not contain expected policy $VAULT_EXPECTED_POLICY"
K8S_JWT=""
LOGIN_PAYLOAD=""
LOGIN_RESPONSE=""
log "Vault Kubernetes-auth succeeded with the expected signing policy"

KEY_FILE="$WORKDIR/id_ed25519"
CERT_FILE="$WORKDIR/id_ed25519-cert.pub"
ssh-keygen -q -t ed25519 -N '' -C 'semaphore-control-tower' -f "$KEY_FILE" </dev/null
chmod 600 "$KEY_FILE"

TASK_USER="${SEMAPHORE_TASK_DETAILS_USERNAME:-operator}"
KEY_ID="semaphore:${TASK_USER}:$(date -u +%Y%m%dT%H%M%SZ)"
SIGN_PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"public_key":sys.stdin.read().strip(),"valid_principals":sys.argv[1],"ttl":sys.argv[2],"key_id":sys.argv[3]}))' \
  "$SSH_PRINCIPAL" "$SSH_CERT_TTL" "$KEY_ID" < "$KEY_FILE.pub")"
SIGN_RESPONSE="$(curl -fsS --max-time 10 -H "X-Vault-Token: $VAULT_TOKEN" \
  -H 'Content-Type: application/json' --data "$SIGN_PAYLOAD" \
  "$VAULT_ADDR/v1/$VAULT_SSH_MOUNT/sign/$VAULT_SSH_ROLE")" || fail "Vault SSH certificate signing failed"
printf '%s' "$SIGN_RESPONSE" | python3 -c 'import json,sys; s=json.load(sys.stdin).get("data",{}).get("signed_key","").strip(); sys.stdout.write(s + ("\n" if s else ""))' > "$CERT_FILE"
[[ -s "$CERT_FILE" ]] || fail "Vault signing response did not contain signed_key"
[[ "$(grep -cve '^[[:space:]]*$' "$CERT_FILE")" -eq 1 ]] || fail "Vault returned an unexpected multi-line SSH certificate"
chmod 600 "$CERT_FILE"
SIGN_PAYLOAD=""
SIGN_RESPONSE=""

CERT_INFO="$WORKDIR/cert-info.txt"
CERT_ERROR="$WORKDIR/cert-error.txt"
if ! ssh-keygen -Lf "$CERT_FILE" > "$CERT_INFO" 2> "$CERT_ERROR"; then
  cat "$CERT_ERROR" >&2 || true
  fail "Vault returned an invalid OpenSSH certificate"
fi
[[ ! -s "$CERT_ERROR" ]] || { cat "$CERT_ERROR" >&2; fail "OpenSSH reported warnings while parsing the Vault certificate"; }
grep -Eq "^[[:space:]]+$SSH_PRINCIPAL([[:space:]]*)$" "$CERT_INFO" \
  || fail "issued SSH certificate does not contain required principal $SSH_PRINCIPAL"
log "Ephemeral SSH certificate issued for principal $SSH_PRINCIPAL (requested TTL $SSH_CERT_TTL)"
grep -E 'Signing CA:|Valid:|Principals:|^[[:space:]]+ansible$' "$CERT_INFO" | sed 's/^/[control-tower] cert: /' || true

for entry in "${TARGET_NODES[@]}"; do
  host="${entry%%:*}"
  ip="${entry##*:}"
  SSH_PROBE_LOG="$WORKDIR/ssh-probe-$host.log"
  if ssh -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityFile="$KEY_FILE" \
      -o CertificateFile="$CERT_FILE" -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" -o ConnectTimeout=8 -o LogLevel=ERROR \
      "$SSH_PRINCIPAL@$ip" 'test "$(id -un)" = "ansible"' 2>"$SSH_PROBE_LOG"; then
    log "Direct Vault-certificate SSH probe passed for $host ($ip)"
  else
    log "Direct Vault-certificate SSH probe failed for $host ($ip); collecting safe client diagnostics"
    ssh -vvv -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityFile="$KEY_FILE" \
      -o CertificateFile="$CERT_FILE" -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" -o ConnectTimeout=8 \
      "$SSH_PRINCIPAL@$ip" true >/dev/null 2>"$SSH_PROBE_LOG" || true
    grep -E 'Offering public key|Server accepts key|Authentications that can continue|sign_and_send_pubkey|Permission denied|certificate|CertificateFile|identity file' "$SSH_PROBE_LOG" \
      | tail -n 30 | sed 's/^/[control-tower] ssh-debug: /' >&2 || true
    fail "Vault certificate was issued but worker SSH authentication rejected it for $SSH_PRINCIPAL@$ip. Check the node TrustedUserCAKeys/AuthorizedPrincipalsFile/account state before changing Ansible"
  fi
done

export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"
export ANSIBLE_HOST_KEY_CHECKING=True
export ANSIBLE_SSH_ARGS="-o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS_FILE -o IdentitiesOnly=yes"

ANSIBLE_ARGS=(
  "$CONTROL_TOWER_PLAYBOOK"
  -e "control_tower_ssh_private_key=$KEY_FILE"
  -e "control_tower_ssh_certificate=$CERT_FILE"
  -e "ansible_user=$SSH_PRINCIPAL"
)
[[ -z "$CONTROL_TOWER_LIMIT" ]] || ANSIBLE_ARGS+=(--limit "$CONTROL_TOWER_LIMIT")

log "Running automation/ansible/$CONTROL_TOWER_PLAYBOOK as $SSH_PRINCIPAL"
[[ -z "$CONTROL_TOWER_LIMIT" ]] || log "Ansible limit: $CONTROL_TOWER_LIMIT"
cd "$ANSIBLE_DIR"
ansible-playbook "${ANSIBLE_ARGS[@]}"
log "Playbook completed successfully; ephemeral credentials will now be revoked and deleted"
