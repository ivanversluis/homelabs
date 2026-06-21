#!/usr/bin/env bash
# Migrate a PVC from storageClassName: longhorn (Delete) to longhorn-worker (Retain)
#
# Prerequisites:
#   - Longhorn backup is configured and a recent backup exists for the target PVC
#   - kubectl context is pointing at the correct cluster
#   - The PVC manifest file path is known (see --manifest flag)
#
# Usage:
#   plan/sc-migration.sh \
#     --namespace <ns> \
#     --pvc <pvc-name> \
#     --deployment <deploy-name> \
#     --manifest <relative/path/to/pvc.yaml>
#
# Example:
#   plan/sc-migration.sh \
#     --namespace forgejo \
#     --pvc forgejo-pvc \
#     --deployment forgejo \
#     --manifest apps/forgejo/forgejo-pvc.yaml

set -euo pipefail

NAMESPACE=""
PVC_NAME=""
DEPLOYMENT=""
MANIFEST=""

usage() {
  grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace|-n) NAMESPACE="$2"; shift 2 ;;
    --pvc|-p)       PVC_NAME="$2";  shift 2 ;;
    --deployment|-d) DEPLOYMENT="$2"; shift 2 ;;
    --manifest|-m)  MANIFEST="$2";  shift 2 ;;
    --help|-h)      usage ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

[[ -z "$NAMESPACE" || -z "$PVC_NAME" || -z "$DEPLOYMENT" || -z "$MANIFEST" ]] && {
  echo "ERROR: all four flags are required."
  usage
}

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
MANIFEST_ABS="$REPO_ROOT/$MANIFEST"

[[ -f "$MANIFEST_ABS" ]] || { echo "ERROR: manifest not found: $MANIFEST_ABS"; exit 1; }

# ─── Preflight checks ────────────────────────────────────────────────────────

echo ""
echo "=== Preflight checks ==="

# Check PVC exists
PVC_SC=$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.storageClassName}' 2>/dev/null) || {
  echo "ERROR: PVC $PVC_NAME not found in namespace $NAMESPACE"
  exit 1
}

if [[ "$PVC_SC" != "longhorn" ]]; then
  echo "ERROR: PVC $PVC_NAME has storageClassName=$PVC_SC, expected longhorn. Aborting."
  exit 1
fi

PV_NAME=$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}')
PV_POLICY=$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')
PV_CAPACITY=$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.capacity.storage}')

if [[ "$PV_POLICY" != "Retain" ]]; then
  echo "ERROR: PV $PV_NAME has reclaimPolicy=$PV_POLICY — must be Retain before migrating."
  echo "  Run: kubectl patch pv $PV_NAME -p '{\"spec\":{\"persistentVolumeReclaimPolicy\":\"Retain\"}}'"
  exit 1
fi

MANIFEST_SC=$(grep 'storageClassName:' "$MANIFEST_ABS" | awk '{print $2}' | head -1)

echo ""
echo "  Namespace:  $NAMESPACE"
echo "  PVC:        $PVC_NAME  ($PVC_SC, $PV_CAPACITY)"
echo "  PV:         $PV_NAME  (reclaimPolicy=$PV_POLICY) ✓"
echo "  Deployment: $DEPLOYMENT"
echo "  Manifest:   $MANIFEST  (storageClassName: $MANIFEST_SC)"
echo ""

# Check manifest is already updated to longhorn-worker
if [[ "$MANIFEST_SC" != "longhorn-worker" ]]; then
  echo "WARNING: manifest still has storageClassName: $MANIFEST_SC"
  echo "  The manifest must be updated to longhorn-worker + volumeName BEFORE"
  echo "  running this script (or Flux will provision a new empty PV)."
  echo ""
  echo "  Required manifest changes:"
  echo "    storageClassName: longhorn-worker"
  echo "    volumeName: $PV_NAME"
  echo ""
  read -rp "  Continue anyway? (type YES to proceed): " CONFIRM
  [[ "$CONFIRM" == "YES" ]] || { echo "Aborted."; exit 0; }
fi

# ─── Confirmation ────────────────────────────────────────────────────────────

echo ""
echo "=== Migration plan ==="
echo "  1. Scale down deployment/$DEPLOYMENT in $NAMESPACE to 0"
echo "  2. Delete PVC $PVC_NAME (PV $PV_NAME stays — Retain)"
echo "  3. Clear PV claimRef → PV becomes Available"
echo "  4. Flux/ArgoCD reconciles → creates new PVC bound to $PV_NAME"
echo "  5. Scale deployment back up to 1"
echo ""
read -rp "Proceed? (type YES to continue): " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Aborted."; exit 0; }

# ─── Step 1: Scale down ───────────────────────────────────────────────────────

echo ""
echo "[1/5] Scaling down deployment/$DEPLOYMENT..."
kubectl scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=0
kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=60s || true
echo "  Done."

# ─── Step 2: Delete PVC ───────────────────────────────────────────────────────

echo ""
echo "[2/5] Deleting PVC $PVC_NAME (PV $PV_NAME will be Released)..."
kubectl delete pvc "$PVC_NAME" -n "$NAMESPACE"
echo "  Done."

# ─── Step 3: Clear claimRef ───────────────────────────────────────────────────

echo ""
echo "[3/5] Clearing PV claimRef to make it Available..."
kubectl patch pv "$PV_NAME" --type=json \
  -p='[{"op":"remove","path":"/spec/claimRef"}]'
PV_PHASE=$(kubectl get pv "$PV_NAME" -o jsonpath='{.status.phase}')
echo "  PV $PV_NAME phase: $PV_PHASE"

# ─── Step 4: Manifest check ───────────────────────────────────────────────────

echo ""
echo "[4/5] Manifest check..."
CURRENT_SC=$(grep 'storageClassName:' "$MANIFEST_ABS" | awk '{print $2}' | head -1)
HAS_VOLUME_NAME=$(grep -c "volumeName: $PV_NAME" "$MANIFEST_ABS" || true)

if [[ "$CURRENT_SC" == "longhorn-worker" && "$HAS_VOLUME_NAME" -gt 0 ]]; then
  echo "  Manifest is correct (longhorn-worker + volumeName). Flux will reconcile automatically."
else
  echo ""
  echo "  ACTION REQUIRED: Update $MANIFEST before scaling up."
  echo ""
  echo "  Add/change these fields in spec:"
  echo "    storageClassName: longhorn-worker"
  echo "    volumeName: $PV_NAME"
  echo ""
  echo "  Then: git add $MANIFEST && git commit -m 'fix(storage): migrate $PVC_NAME to longhorn-worker' && git push"
  echo ""
  read -rp "  Press Enter once committed and Flux has reconciled, then this script will scale up..."
fi

# ─── Step 5: Scale up ────────────────────────────────────────────────────────

echo ""
echo "[5/5] Verifying PVC is Bound before scaling up..."
for i in $(seq 1 24); do
  PHASE=$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Missing")
  BOUND_PV=$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")
  echo "  Attempt $i/24: PVC phase=$PHASE, volumeName=${BOUND_PV:-<pending>}"
  if [[ "$PHASE" == "Bound" ]]; then
    if [[ "$BOUND_PV" == "$PV_NAME" ]]; then
      echo "  PVC is Bound to correct PV $PV_NAME ✓"
    else
      echo "  WARNING: PVC is Bound but to $BOUND_PV, not the original $PV_NAME!"
      echo "  Data may be on a NEW empty PV. DO NOT scale up — investigate first."
      exit 1
    fi
    break
  fi
  sleep 5
done

FINAL_PHASE=$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Missing")
if [[ "$FINAL_PHASE" != "Bound" ]]; then
  echo "  ERROR: PVC not Bound after 2 minutes. Not scaling up. Check Flux/ArgoCD."
  exit 1
fi

kubectl scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=1
kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=120s

echo ""
echo "=== Migration complete ==="
NEW_SC=$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.storageClassName}')
echo "  PVC $PVC_NAME in $NAMESPACE: storageClassName=$NEW_SC, volumeName=$PV_NAME"
kubectl get pv "$PV_NAME" --no-headers
