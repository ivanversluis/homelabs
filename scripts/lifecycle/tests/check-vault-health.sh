#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_CHECK="$SCRIPT_DIR/../check-vault-health.sh"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/vault-health-test.XXXXXX")"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

python3 - "$WORKDIR/port" <<'PY' &
import http.server
import json
import sys

responses = {
    "/healthy": (200, {"initialized": True, "sealed": False}),
    "/sealed": (503, {"initialized": True, "sealed": True}),
    "/uninitialized": (501, {"initialized": False, "sealed": True}),
    "/unexpected": (500, {"initialized": True, "sealed": False}),
}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0].removeprefix("/healthy").removeprefix("/sealed").removeprefix("/uninitialized").removeprefix("/invalid").removeprefix("/unexpected")
        prefix = self.path.split("/v1/", 1)[0]
        if prefix == "/invalid":
            status, body = 200, b"not-json"
        else:
            status, payload = responses.get(prefix, (404, {"initialized": True, "sealed": False}))
            body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="utf-8") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
PY
SERVER_PID="$!"

for _ in {1..50}; do
  [[ -s "$WORKDIR/port" ]] && break
  sleep 0.1
done
[[ -s "$WORKDIR/port" ]] || { echo "test server did not start" >&2; exit 1; }
PORT="$(cat "$WORKDIR/port")"

expect_success() {
  local path="$1"
  local expected="$2"
  local output
  output="$(bash "$HEALTH_CHECK" "http://127.0.0.1:$PORT/$path" 2>&1)" \
    || { echo "expected success for $path: $output" >&2; exit 1; }
  [[ "$output" == *"$expected"* ]] \
    || { echo "missing success message for $path: $output" >&2; exit 1; }
}

expect_failure() {
  local path="$1"
  local expected="$2"
  local output
  local rc
  set +e
  output="$(bash "$HEALTH_CHECK" "http://127.0.0.1:$PORT/$path" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || { echo "expected failure for $path" >&2; exit 1; }
  [[ "$output" == *"$expected"* ]] \
    || { echo "missing failure message for $path: $output" >&2; exit 1; }
}

expect_success healthy "reachable, initialized, and unsealed (HTTP 200)"
expect_failure sealed "Vault is sealed (HTTP 503)"
expect_failure uninitialized "Vault is not initialized (HTTP 501)"
expect_failure invalid "returned invalid JSON (HTTP 200)"
expect_failure unexpected "unexpected HTTP 500"

kill "$SERVER_PID"
wait "$SERVER_PID" >/dev/null 2>&1 || true
SERVER_PID=""
expect_failure healthy "Vault health endpoint is not reachable"

echo "Vault health classification tests passed"
