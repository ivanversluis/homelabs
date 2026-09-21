#!/usr/bin/env bash
# Classify Vault health without treating sealed HTTP responses as transport failures.
set -Eeuo pipefail

VAULT_ADDR="${1:-${VAULT_ADDR:-}}"
VAULT_HEALTH_TIMEOUT="${VAULT_HEALTH_TIMEOUT:-8}"

fail() {
  printf '[vault-health] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -n "$VAULT_ADDR" ]] || fail "Vault address is required"
command -v curl >/dev/null 2>&1 || fail "required command 'curl' is not available"
command -v python3 >/dev/null 2>&1 || fail "required command 'python3' is not available"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/vault-health.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT INT TERM
RESPONSE_FILE="$WORKDIR/response.json"
HEALTH_URL="${VAULT_ADDR%/}/v1/sys/health?standbyok=true&perfstandbyok=true"

if ! HTTP_STATUS="$(curl --silent --show-error --max-time "$VAULT_HEALTH_TIMEOUT" \
    --output "$RESPONSE_FILE" --write-out '%{http_code}' "$HEALTH_URL")"; then
  fail "Vault health endpoint is not reachable"
fi

[[ "$HTTP_STATUS" =~ ^[0-9]{3}$ ]] \
  || fail "Vault health endpoint returned an invalid HTTP status"

if ! HEALTH_STATE="$(python3 - "$RESPONSE_FILE" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as response:
        data = json.load(response)
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)

initialized = data.get("initialized")
sealed = data.get("sealed")
if not isinstance(initialized, bool) or not isinstance(sealed, bool):
    raise SystemExit(1)

print(f"{int(initialized)}:{int(sealed)}")
PY
)"; then
  fail "Vault health endpoint returned invalid JSON (HTTP $HTTP_STATUS)"
fi

case "$HEALTH_STATE" in
  0:*)
    fail "Vault is not initialized (HTTP $HTTP_STATUS)"
    ;;
  1:1)
    fail "Vault is sealed (HTTP $HTTP_STATUS); use the trusted recovery path to unseal it"
    ;;
  1:0)
    if [[ "$HTTP_STATUS" != 2* ]]; then
      fail "Vault reported initialized and unsealed with unexpected HTTP $HTTP_STATUS"
    fi
    ;;
  *)
    fail "Vault health endpoint returned an unsupported state (HTTP $HTTP_STATUS)"
    ;;
esac

printf '[vault-health] Vault is reachable, initialized, and unsealed (HTTP %s)\n' "$HTTP_STATUS"
