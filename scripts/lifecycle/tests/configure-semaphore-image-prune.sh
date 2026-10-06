#!/usr/bin/env bash
set -Eeuo pipefail

# The same file acts as the mock curl binary for child processes.
if [[ "${MOCK_CURL_MODE:-false}" == "true" ]]; then
  method="GET"
  payload=""
  url=""
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
    */api/info)
      printf '{"schedule_timezone":"Europe/Amsterdam"}'
      ;;
    */api/projects\?*)
      printf '[{"id":11,"name":"Homelab"}]'
      ;;
    */api/project/11/repositories\?*)
      printf '[{"id":22,"name":"homelabs","git_url":"https://github.com/ivanversluis/homelabs.git"}]'
      ;;
    */api/project/11/templates\?app=bash)
      if [[ "$MOCK_CURL_STATE" == "existing" ]]; then
        printf '[{"id":33,"name":"Homelab Ops - Weekly containerd image prune"}]'
      else
        printf '[]'
      fi
      ;;
    */api/project/11/templates)
      printf '{"id":33}'
      ;;
    */api/project/11/templates/33)
      ;;
    */api/project/11/schedules)
      if [[ "$method" == "POST" ]]; then
        printf '{"id":44}'
      elif [[ "$MOCK_CURL_STATE" == "existing" ]]; then
        printf '[{"id":44,"name":"Weekly containerd image prune"}]'
      else
        printf '[]'
      fi
      ;;
    */api/project/11/schedules/44)
      ;;
    *)
      printf 'unexpected mock URL: %s\n' "$url" >&2
      exit 1
      ;;
  esac
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/lifecycle/configure-semaphore-image-prune.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-semaphore-image-prune.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

run_case() {
  local state="$1"
  local log_file="$TMP_DIR/$state.log"

  MOCK_CURL_MODE=true \
  MOCK_CURL_STATE="$state" \
  MOCK_CURL_LOG="$log_file" \
  CURL_BIN="$SCRIPT_DIR/configure-semaphore-image-prune.sh" \
  SEMAPHORE_URL=https://semaphore.invalid \
  SEMAPHORE_API_TOKEN=test-token \
    bash "$TARGET_SCRIPT" >/dev/null

  grep -F $'GET\thttps://semaphore.invalid/api/info' "$log_file" >/dev/null
  grep -F 'scripts/lifecycle/semaphore-control-tower-run.sh' "$log_file" >/dev/null
  grep -F '[\"playbook=playbooks/96-containerd-image-prune.yml\",\"limit=k8s_homelab\"]' "$log_file" >/dev/null
  grep -F '"cron_format":"0 4 * * 0"' "$log_file" >/dev/null
  grep -F '"active":true' "$log_file" >/dev/null

  if [[ "$state" == "create" ]]; then
    grep -F $'POST\thttps://semaphore.invalid/api/project/11/templates' "$log_file" >/dev/null
    grep -F $'POST\thttps://semaphore.invalid/api/project/11/schedules' "$log_file" >/dev/null
  else
    grep -F $'PUT\thttps://semaphore.invalid/api/project/11/templates/33' "$log_file" >/dev/null
    grep -F $'PUT\thttps://semaphore.invalid/api/project/11/schedules/44' "$log_file" >/dev/null
  fi
}

run_case create
run_case existing
printf 'Semaphore image-prune provisioning tests passed\n'
