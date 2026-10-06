#!/usr/bin/env bash
# Idempotently create/update the Semaphore task template and weekly schedule for
# automation/ansible/playbooks/96-containerd-image-prune.yml.
set -Eeuo pipefail

SEMAPHORE_NAMESPACE="${SEMAPHORE_NAMESPACE:-semaphoreui}"
SEMAPHORE_SERVICE="${SEMAPHORE_SERVICE:-semaphoreui}"
SEMAPHORE_SECRET="${SEMAPHORE_SECRET:-semaphoreui-secrets}"
SEMAPHORE_LOCAL_PORT="${SEMAPHORE_LOCAL_PORT:-3000}"
SEMAPHORE_URL="${SEMAPHORE_URL:-}"
SEMAPHORE_PROJECT_NAME="${SEMAPHORE_PROJECT_NAME:-Homelab}"
SEMAPHORE_REPOSITORY_NAME="${SEMAPHORE_REPOSITORY_NAME:-homelabs}"
SEMAPHORE_REPOSITORY_URL_MATCH="${SEMAPHORE_REPOSITORY_URL_MATCH:-ivanversluis/homelabs}"
SEMAPHORE_TEMPLATE_NAME="${SEMAPHORE_TEMPLATE_NAME:-Homelab Ops - Weekly containerd image prune}"
SEMAPHORE_SCHEDULE_NAME="${SEMAPHORE_SCHEDULE_NAME:-Weekly containerd image prune}"
SEMAPHORE_CRON="${SEMAPHORE_CRON:-0 4 * * 0}"
SEMAPHORE_EXPECTED_TIMEZONE="${SEMAPHORE_EXPECTED_TIMEZONE:-Europe/Amsterdam}"
SEMAPHORE_GIT_BRANCH="${SEMAPHORE_GIT_BRANCH:-main}"
CURL_BIN="${CURL_BIN:-curl}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

PORT_FORWARD_PID=""
COOKIE_FILE=""

log() { printf '[semaphore-image-prune] %s\n' "$*"; }
fail() { printf '[semaphore-image-prune] ERROR: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "required command '$1' is not available"; }

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$COOKIE_FILE" ]]; then
    rm -f "$COOKIE_FILE"
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

require_cmd "$CURL_BIN"
require_cmd jq

if [[ -z "$SEMAPHORE_URL" ]]; then
  require_cmd "$KUBECTL_BIN"
  SEMAPHORE_URL="http://127.0.0.1:${SEMAPHORE_LOCAL_PORT}"
  log "Starting a temporary port-forward to service/$SEMAPHORE_SERVICE"
  "$KUBECTL_BIN" -n "$SEMAPHORE_NAMESPACE" port-forward \
    "service/$SEMAPHORE_SERVICE" "${SEMAPHORE_LOCAL_PORT}:3000" \
    >/dev/null 2>&1 &
  PORT_FORWARD_PID=$!

  for _ in $(seq 1 30); do
    if "$CURL_BIN" --silent --fail --max-time 1 "$SEMAPHORE_URL/api/ping" >/dev/null 2>&1; then
      break
    fi
    if ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
      fail "Semaphore port-forward exited before the API became ready"
    fi
    sleep 1
  done
  "$CURL_BIN" --silent --fail --max-time 2 "$SEMAPHORE_URL/api/ping" >/dev/null \
    || fail "Semaphore API did not become ready through the port-forward"
fi

SEMAPHORE_URL="${SEMAPHORE_URL%/}"
case "$SEMAPHORE_URL" in
  https://*|http://127.0.0.1:*|http://localhost:*) ;;
  *) fail "SEMAPHORE_URL must use HTTPS, or HTTP only through localhost port-forwarding" ;;
esac

AUTH_ARGS=()
if [[ -n "${SEMAPHORE_API_TOKEN:-}" ]]; then
  AUTH_ARGS=(-H "Authorization: Bearer $SEMAPHORE_API_TOKEN")
  log "Using the supplied Semaphore API token"
else
  require_cmd "$KUBECTL_BIN"
  COOKIE_FILE="$(mktemp "${TMPDIR:-/tmp}/semaphore-image-prune-cookie.XXXXXX")"
  chmod 600 "$COOKIE_FILE"

  if [[ -z "${SEMAPHORE_USERNAME:-}" || -z "${SEMAPHORE_PASSWORD:-}" ]]; then
    log "Loading Semaphore admin credentials from Secret/$SEMAPHORE_SECRET without printing them"
    secret_json="$($KUBECTL_BIN -n "$SEMAPHORE_NAMESPACE" get secret "$SEMAPHORE_SECRET" -o json)"
    SEMAPHORE_USERNAME="$(jq -er '.data.username | @base64d' <<<"$secret_json")" \
      || fail "Secret/$SEMAPHORE_SECRET does not contain a valid username key"
    SEMAPHORE_PASSWORD="$(jq -er '.data.password | @base64d' <<<"$secret_json")" \
      || fail "Secret/$SEMAPHORE_SECRET does not contain a valid password key"
    secret_json=""
  fi

  login_payload="$(jq -cn --arg auth "$SEMAPHORE_USERNAME" --arg password "$SEMAPHORE_PASSWORD" \
    '{auth: $auth, password: $password}')"
  "$CURL_BIN" --silent --show-error --fail-with-body \
    --cookie-jar "$COOKIE_FILE" \
    -H 'Content-Type: application/json' \
    --data "$login_payload" \
    "$SEMAPHORE_URL/api/auth/login" >/dev/null \
    || fail "Semaphore API login failed"
  login_payload=""
  SEMAPHORE_PASSWORD=""
  AUTH_ARGS=(--cookie "$COOKIE_FILE")
  log "Semaphore API login succeeded"
fi

api() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local args=(
    --silent
    --show-error
    --fail-with-body
    --request "$method"
    -H 'Accept: application/json'
    "${AUTH_ARGS[@]}"
  )
  if [[ -n "$payload" ]]; then
    args+=(-H 'Content-Type: application/json' --data "$payload")
  fi
  "$CURL_BIN" "${args[@]}" "$SEMAPHORE_URL$path"
}

select_named_id() {
  local collection="$1"
  local name="$2"
  local kind="$3"
  local matches
  matches="$(jq --arg name "$name" '[.[] | select((.name | ascii_downcase) == ($name | ascii_downcase))]' <<<"$collection")"
  case "$(jq 'length' <<<"$matches")" in
    1) jq -r '.[0].id' <<<"$matches" ;;
    0) return 1 ;;
    *) fail "multiple $kind objects match name '$name'" ;;
  esac
}

info_json="$(api GET /api/info)"
schedule_timezone="$(jq -r '.schedule_timezone // "UTC"' <<<"$info_json")"
[[ "$schedule_timezone" == "$SEMAPHORE_EXPECTED_TIMEZONE" ]] \
  || fail "Semaphore schedule timezone is '$schedule_timezone', expected '$SEMAPHORE_EXPECTED_TIMEZONE'"
log "Schedule timezone verified: $schedule_timezone"

projects_json="$(api GET '/api/projects?sort=name&order=asc')"
if ! project_id="$(select_named_id "$projects_json" "$SEMAPHORE_PROJECT_NAME" project)"; then
  if [[ "$(jq 'length' <<<"$projects_json")" -eq 1 ]]; then
    project_id="$(jq -r '.[0].id' <<<"$projects_json")"
    log "Project '$SEMAPHORE_PROJECT_NAME' was not found; using the only available project: $(jq -r '.[0].name' <<<"$projects_json")"
  else
    fail "project '$SEMAPHORE_PROJECT_NAME' was not found; set SEMAPHORE_PROJECT_NAME explicitly"
  fi
fi

repositories_json="$(api GET "/api/project/$project_id/repositories?sort=name&order=asc")"
if ! repository_id="$(select_named_id "$repositories_json" "$SEMAPHORE_REPOSITORY_NAME" repository)"; then
  repository_matches="$(jq --arg match "$SEMAPHORE_REPOSITORY_URL_MATCH" \
    '[.[] | select((.git_url // "") | contains($match))]' <<<"$repositories_json")"
  [[ "$(jq 'length' <<<"$repository_matches")" -eq 1 ]] \
    || fail "repository '$SEMAPHORE_REPOSITORY_NAME' was not found uniquely; set SEMAPHORE_REPOSITORY_NAME"
  repository_id="$(jq -r '.[0].id' <<<"$repository_matches")"
fi

template_payload="$(jq -cn \
  --argjson project_id "$project_id" \
  --argjson repository_id "$repository_id" \
  --arg name "$SEMAPHORE_TEMPLATE_NAME" \
  --arg branch "$SEMAPHORE_GIT_BRANCH" \
  --arg arguments '["playbook=playbooks/96-containerd-image-prune.yml","limit=k8s_homelab"]' \
  '{
    project_id: $project_id,
    repository_id: $repository_id,
    environment_ids: [],
    name: $name,
    playbook: "scripts/lifecycle/semaphore-control-tower-run.sh",
    arguments: $arguments,
    description: "Weekly CRI-native cleanup of unused containerd images, one Kubernetes node at a time, with before/after capacity evidence.",
    app: "bash",
    type: "",
    git_branch: $branch,
    allow_override_args_in_task: false,
    allow_override_branch_in_task: false,
    allow_parallel_tasks: false,
    suppress_success_alerts: false,
    task_params: {}
  }')"

templates_json="$(api GET "/api/project/$project_id/templates?app=bash")"
template_matches="$(jq --arg name "$SEMAPHORE_TEMPLATE_NAME" '[.[] | select(.name == $name)]' <<<"$templates_json")"
case "$(jq 'length' <<<"$template_matches")" in
  0)
    template_json="$(api POST "/api/project/$project_id/templates" "$template_payload")"
    template_id="$(jq -er '.id' <<<"$template_json")"
    log "Created task template '$SEMAPHORE_TEMPLATE_NAME' (ID $template_id)"
    ;;
  1)
    template_id="$(jq -r '.[0].id' <<<"$template_matches")"
    template_payload="$(jq -c --argjson id "$template_id" '. + {id: $id}' <<<"$template_payload")"
    api PUT "/api/project/$project_id/templates/$template_id" "$template_payload" >/dev/null
    log "Updated task template '$SEMAPHORE_TEMPLATE_NAME' (ID $template_id)"
    ;;
  *) fail "multiple templates match '$SEMAPHORE_TEMPLATE_NAME'; remove the duplicates first" ;;
esac

schedule_payload="$(jq -cn \
  --argjson project_id "$project_id" \
  --argjson template_id "$template_id" \
  --arg name "$SEMAPHORE_SCHEDULE_NAME" \
  --arg cron "$SEMAPHORE_CRON" \
  '{
    project_id: $project_id,
    template_id: $template_id,
    name: $name,
    cron_format: $cron,
    active: true,
    type: "",
    delete_after_run: false
  }')"

schedules_json="$(api GET "/api/project/$project_id/schedules")"
schedule_matches="$(jq --arg name "$SEMAPHORE_SCHEDULE_NAME" '[.[] | select(.name == $name)]' <<<"$schedules_json")"
case "$(jq 'length' <<<"$schedule_matches")" in
  0)
    schedule_json="$(api POST "/api/project/$project_id/schedules" "$schedule_payload")"
    schedule_id="$(jq -er '.id' <<<"$schedule_json")"
    log "Created weekly schedule '$SEMAPHORE_SCHEDULE_NAME' (ID $schedule_id)"
    ;;
  1)
    schedule_id="$(jq -r '.[0].id' <<<"$schedule_matches")"
    schedule_payload="$(jq -c --argjson id "$schedule_id" '. + {id: $id}' <<<"$schedule_payload")"
    api PUT "/api/project/$project_id/schedules/$schedule_id" "$schedule_payload" >/dev/null
    log "Updated weekly schedule '$SEMAPHORE_SCHEDULE_NAME' (ID $schedule_id)"
    ;;
  *) fail "multiple schedules match '$SEMAPHORE_SCHEDULE_NAME'; remove the duplicates first" ;;
esac

log "Provisioning complete: cron '$SEMAPHORE_CRON' in $schedule_timezone, branch '$SEMAPHORE_GIT_BRANCH'"
