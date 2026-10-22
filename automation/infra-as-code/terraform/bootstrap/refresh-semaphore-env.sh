#!/usr/bin/env bash
# Run after updating Vault inputs. Never restart on a failed/stale ESO refresh.
set -euo pipefail

sync_timeout=${ESO_SYNC_TIMEOUT_SECONDS:-120}
[[ "$sync_timeout" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid sync timeout" >&2; exit 1; }

namespace=semaphoreui
name=semaphoreui-terraform-env
previous=$(kubectl -n "$namespace" get externalsecret "$name" -o json)
previous_refresh=$(jq -r '.status.refreshTime // ""' <<< "$previous")
previous_version=$(jq -r '.status.syncedResourceVersion // ""' <<< "$previous")
kubectl -n "$namespace" annotate externalsecret "$name" \
  "force-sync=$(date +%s)-${RANDOM}" --overwrite

deadline=$((SECONDS + sync_timeout))
while (( SECONDS < deadline )); do
  current=$(kubectl -n "$namespace" get externalsecret "$name" -o json)
  if jq -e --arg refresh "$previous_refresh" --arg version "$previous_version" '
    (.status.refreshTime // "") != "" and
    .status.refreshTime != $refresh and
    (.status.syncedResourceVersion // "") != "" and
    .status.syncedResourceVersion != $version and
    any(.status.conditions[]?; .type == "Ready" and .status == "True")
  ' <<< "$current" > /dev/null; then
    # Check only presence; never print or decode the token.
    kubectl -n "$namespace" get secret "$name" -o json | jq -e '
      (.data.TF_VAR_cloudflare_api_token // "") | length > 0
    ' > /dev/null
    kubectl -n "$namespace" rollout restart deploy/semaphoreui
    kubectl -n "$namespace" rollout status deploy/semaphoreui --timeout=180s
    exit 0
  fi
  sleep 2
done

echo "ExternalSecret did not complete a fresh successful sync within ${sync_timeout}s; Semaphore was not restarted." >&2
exit 1
