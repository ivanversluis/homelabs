#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OPENCLAW_NAMESPACE:-openclaw}"
SELECTOR="${OPENCLAW_SELECTOR:-app.kubernetes.io/name=openclaw}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required but not found in PATH" >&2
  exit 1
fi

POD="$(kubectl -n "$NAMESPACE" get pod -l "$SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -z "$POD" ]]; then
  echo "No OpenClaw pod found in namespace '$NAMESPACE' with selector '$SELECTOR'" >&2
  exit 1
fi

echo "Using pod: $POD" >&2
kubectl -n "$NAMESPACE" exec "$POD" -- node -e '
const skillPath = "/home/node/.openclaw/skills/k8s-monitor.js";
try {
  const mod = require(skillPath);
  const report = mod && (mod.report || mod);
  console.log(JSON.stringify(report, null, 2));
} catch (err) {
  console.error(`Failed to load ${skillPath}: ${err.message}`);
  process.exit(1);
}
'
