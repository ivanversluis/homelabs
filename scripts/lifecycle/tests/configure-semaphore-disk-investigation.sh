#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${MOCK_CURL_MODE:-false}" == true ]]; then
  method=GET
  payload=''
  url=''
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --request) method="$2"; shift 2 ;;
      --data) payload="$2"; shift 2 ;;
      -H|--cookie|--cookie-jar|--max-time) shift 2 ;;
      --silent|--show-error|--fail|--fail-with-body) shift ;;
      *) url="$1"; shift ;;
    esac
  done

  printf '%s\t%s\t%s\n' "$method" "$url" "$payload" >> "$MOCK_CURL_LOG"
  case "$url" in
    */api/projects\?*) printf '[{"id":11,"name":"Homelab"}]' ;;
    */api/project/11/repositories\?*)
      printf '[{"id":22,"name":"homelabs","git_url":"https://github.com/ivanversluis/homelabs.git"}]' ;;
    */api/project/11/templates\?app=bash)
      if [[ "$MOCK_CURL_STATE" == existing ]]; then
        printf '[{"id":33,"name":"Homelab Ops - Disk path investigation (k8s-worker03)"}]'
      else
        printf '[]'
      fi
      ;;
    */api/project/11/templates) printf '{"id":33}' ;;
    */api/project/11/templates/33) ;;
    *) printf 'Unexpected URL: %s\n' "$url" >&2; exit 1 ;;
  esac
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TARGET="$REPO_ROOT/scripts/lifecycle/configure-semaphore-disk-investigation.sh"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
cp "$0" "$TEMP/mock-curl"
chmod 755 "$TEMP/mock-curl"

for state in create existing; do
  log="$TEMP/$state.log"
  MOCK_CURL_MODE=true MOCK_CURL_STATE="$state" MOCK_CURL_LOG="$log" \
    CURL_BIN="$TEMP/mock-curl" SEMAPHORE_URL=https://semaphore.invalid \
    SEMAPHORE_API_TOKEN=test-token SEMAPHORE_LIMIT=k8s-worker03 \
    bash "$TARGET" > "$TEMP/$state.stdout"

  grep -F 'scripts/lifecycle/semaphore-control-tower-run.sh' "$log" > /dev/null
  grep -F 'playbook=playbooks/97-disk-path-investigation.yml' "$log" > /dev/null
  grep -F 'limit=k8s-worker03' "$log" > /dev/null
  grep -F '"allow_override_args_in_task":false' "$log" > /dev/null
  grep -F 'Homelab Ops - Disk path investigation (k8s-worker03)' "$log" > /dev/null
  if grep -F '/schedules' "$log" > /dev/null; then
    echo 'ERROR: read-only manual task created a schedule' >&2
    exit 1
  fi

  if [[ "$state" == create ]]; then
    grep -F $'POST\thttps://semaphore.invalid/api/project/11/templates' "$log" > /dev/null
  else
    grep -F $'PUT\thttps://semaphore.invalid/api/project/11/templates/33' "$log" > /dev/null
  fi
done

if SEMAPHORE_LIMIT='invalid-node' bash "$TARGET" > "$TEMP/invalid.stdout" 2>&1; then
  echo 'ERROR: invalid Semaphore limit accepted' >&2
  exit 1
fi

printf 'PASS: idempotent manual-only Semaphore disk investigation provisioning\n'
