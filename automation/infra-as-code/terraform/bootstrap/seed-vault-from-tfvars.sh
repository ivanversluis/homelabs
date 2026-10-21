#!/usr/bin/env bash
# Seed Vault secret/infra/terraform (Semaphore Terraform inputs) from a local
# terraform.tfvars, without printing or passing any secret on a command line.
#
#   ./seed-vault-from-tfvars.sh [--dry-run] [--force] [path/to/terraform.tfvars]
#
# - Reads simple `key = "value"` lines from the tfvars file.
# - gatus_* values and vault_prometheus_metrics_token that are missing from the
#   tfvars are carried over from their current Vault secrets (infra/gatus,
#   infra/vault) so Terraform does not overwrite them with empty strings.
# - Refuses to overwrite an existing secret/infra/terraform unless --force.
# - The Vault token is read silently and sent to the Vault pod over stdin.
# Only key names and set/empty status are printed, never values.
set -euo pipefail

VAULT_NS="${VAULT_NS:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
DRY_RUN=false
FORCE=false
TFVARS=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force) FORCE=true ;;
    -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
    *) TFVARS="$arg" ;;
  esac
done
TFVARS="${TFVARS:-$(dirname "$0")/../deployments/terraform.tfvars}"

command -v kubectl > /dev/null || { echo "kubectl is required" >&2; exit 1; }
command -v python3 > /dev/null || { echo "python3 is required" >&2; exit 1; }
[[ -f "$TFVARS" ]] || { echo "tfvars file not found: $TFVARS" >&2; exit 1; }

umask 077
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  read -rsp "Vault token (admin/root, not stored): " VAULT_TOKEN
  echo
fi

# Run a vault command in the Vault pod. The token is the first stdin line so it
# never appears in process arguments; any further stdin is passed to vault.
vault_run() {
  { printf '%s\n' "$VAULT_TOKEN"; cat; } \
    | kubectl exec -i -n "$VAULT_NS" "$VAULT_POD" -- \
      sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"' sh "$@"
}

vault_run kv get -format=json -mount=secret infra/gatus < /dev/null > "$WORK/gatus.json" 2> /dev/null || echo '{}' > "$WORK/gatus.json"
vault_run kv get -format=json -mount=secret infra/vault < /dev/null > "$WORK/vault.json" 2> /dev/null || echo '{}' > "$WORK/vault.json"
if vault_run kv get -format=json -mount=secret infra/terraform < /dev/null > /dev/null 2>&1; then
  EXISTS=true
else
  EXISTS=false
fi

python3 - "$TFVARS" "$WORK" "$EXISTS" "$FORCE" << 'PY'
import json, re, sys

tfvars, work, exists, force = sys.argv[1], sys.argv[2], sys.argv[3] == "true", sys.argv[4] == "true"
KEYS = [
    "domain", "authentik_url", "authentik_token",
    "cloudflare_api_token", "cloudflare_account_id", "cloudflare_tunnel_id",
    "cloudflare_team_name", "cloudflare_zone_id", "vault_prometheus_metrics_token",
    "gatus_discord_webhook_url", "gatus_portainer_monitor_token", "gatus_gitlab_monitor_token",
]

values = {}
for line in open(tfvars):
    m = re.match(r'^\s*([A-Za-z0-9_]+)\s*=\s*"(.*)"\s*(#.*)?$', line)
    if m:
        values[m.group(1)] = m.group(2)


def current(path):
    try:
        return json.load(open(f"{work}/{path}.json"))["data"]["data"]
    except (KeyError, ValueError, TypeError):
        return {}


gatus, vault = current("gatus"), current("vault")
fallbacks = {
    "vault_prometheus_metrics_token": vault.get("prometheus-metrics-token"),
    "gatus_discord_webhook_url": gatus.get("DISCORD_WEBHOOK_URL"),
    "gatus_portainer_monitor_token": gatus.get("PORTAINER_MONITOR_TOKEN"),
    "gatus_gitlab_monitor_token": gatus.get("GITLAB_MONITOR_TOKEN"),
}

payload, report = {}, []
for key in KEYS:
    if values.get(key):
        payload[key], source = values[key], "tfvars"
    elif fallbacks.get(key):
        payload[key], source = fallbacks[key], "current Vault secret"
    else:
        payload[key], source = "", "empty"
    report.append((key, source))

required = [k for k in KEYS if not k.startswith("gatus_")]
missing = [k for k in required if not payload[k]]
for key, source in report:
    print(f"  {key:38} <- {source}")
if missing:
    sys.exit(f"ERROR: required values missing: {', '.join(missing)}")
if exists and not force:
    sys.exit("ERROR: secret/infra/terraform already exists; use --force to overwrite")
json.dump(payload, open(f"{work}/payload.json", "w"))
PY

if $DRY_RUN; then
  echo "Dry run: nothing written."
  exit 0
fi

vault_run kv put -mount=secret infra/terraform - < "$WORK/payload.json" > /dev/null
echo "Written secret/infra/terraform. Keys now present:"
vault_run kv get -format=json -mount=secret infra/terraform < /dev/null \
  | python3 -c 'import json,sys; print("  " + ", ".join(sorted(json.load(sys.stdin)["data"]["data"])))'
