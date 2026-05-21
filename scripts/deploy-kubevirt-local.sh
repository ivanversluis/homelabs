#!/usr/bin/env bash
# ============================================================================
# deploy-kubevirt-local.sh
# ============================================================================
# Bootstraps KubeVirt + CDI + local-path-provisioner on k8s-homelab.
#
# Run this script ONCE before Flux takes over ongoing reconciliation.
# All operators are pinned to specific versions and downloaded locally
# before applying — never piped directly from URLs.
#
# Usage:
#   ./scripts/deploy-kubevirt-local.sh [--skip-flux-suspend] [--dry-run]
#
# Requirements on the workstation:
#   kubectl, flux (CLI), virtctl (optional for final test)
#
# Requirements on k8s-worker03 (already confirmed by prepare-kvm.sh):
#   /dev/kvm exists, kvm_intel module loaded
# ============================================================================
set -euo pipefail

KUBEVIRT_VERSION="v1.8.2"
CDI_VERSION="v1.65.0"

KUBEVIRT_OPERATOR_URL="https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
CDI_OPERATOR_URL="https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/kubevirt-deploy.XXXXXX)"

DRY_RUN=false
SKIP_SUSPEND=false

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)           DRY_RUN=true; shift ;;
    --skip-flux-suspend) SKIP_SUSPEND=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

apply() {
  if $DRY_RUN; then
    echo -e "${YELLOW}[DRY-RUN] kubectl apply -f $*${NC}"
  else
    kubectl apply -f "$@"
  fi
}

wait_for() {
  local resource="$1" ns="$2" condition="$3" timeout="${4:-300s}"
  echo -e "${CYAN}  Waiting for $resource in $ns ($condition, timeout: $timeout)...${NC}"
  if ! $DRY_RUN; then
    kubectl wait "$resource" -n "$ns" --for="$condition" --timeout="$timeout"
  fi
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  KubeVirt + CDI Bootstrap — k8s-homelab                     ║${NC}"
echo -e "${BOLD}║  KubeVirt: ${KUBEVIRT_VERSION}   CDI: ${CDI_VERSION}                     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ─── Step 0: Pre-flight checks ────────────────────────────────────────────────
echo -e "${BOLD}[0/7] Pre-flight checks${NC}"

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}ERROR: Cannot reach cluster. Check kubeconfig.${NC}"; exit 1
fi
echo -e "  ${GREEN}✓${NC} kubectl cluster access OK"

if ! kubectl get node k8s-worker03 &>/dev/null; then
  echo -e "${RED}ERROR: Node k8s-worker03 not found in cluster.${NC}"; exit 1
fi
echo -e "  ${GREEN}✓${NC} k8s-worker03 found"

# Verify KVM on worker03
KVM_STATUS=$(kubectl get node k8s-worker03 -o jsonpath='{.status.capacity.devices\.kubevirt\.io/kvm}' 2>/dev/null || echo "")
if [[ -z "$KVM_STATUS" ]]; then
  echo -e "  ${YELLOW}⚠${NC}  k8s-worker03: KubeVirt node-labeller not yet running (expected before virt-handler)"
  echo -e "     KVM was verified manually via prepare-kvm.sh — continuing."
else
  echo -e "  ${GREEN}✓${NC} k8s-worker03: KVM device visible ($KVM_STATUS)"
fi

# ─── Step 1: Suspend Flux ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[1/7] Suspending Flux reconciliation${NC}"

if $SKIP_SUSPEND; then
  echo -e "  ${YELLOW}⊘${NC}  --skip-flux-suspend passed, Flux reconciliation NOT suspended."
  echo -e "     WARNING: Flux may overwrite changes while bootstrap is in progress."
elif $DRY_RUN; then
  echo -e "${YELLOW}[DRY-RUN] flux suspend kustomization --all${NC}"
else
  flux suspend kustomization --all
  echo -e "  ${GREEN}✓${NC} All Flux Kustomizations suspended"
fi

# ─── Step 2: Download operator manifests ──────────────────────────────────────
echo ""
echo -e "${BOLD}[2/7] Downloading operator manifests (pinned versions)${NC}"

echo "  Downloading KubeVirt operator ${KUBEVIRT_VERSION}..."
curl -sSfL "$KUBEVIRT_OPERATOR_URL" -o "${TMP_DIR}/kubevirt-operator.yaml"
echo -e "  ${GREEN}✓${NC} kubevirt-operator.yaml saved to ${TMP_DIR}/"

echo "  Downloading CDI operator ${CDI_VERSION}..."
curl -sSfL "$CDI_OPERATOR_URL" -o "${TMP_DIR}/cdi-operator.yaml"
echo -e "  ${GREEN}✓${NC} cdi-operator.yaml saved to ${TMP_DIR}/"

echo ""
echo -e "${YELLOW}  ─── SECURITY REVIEW ─────────────────────────────────────────────${NC}"
echo -e "  SHA256 checksums of downloaded manifests:"
sha256sum "${TMP_DIR}/kubevirt-operator.yaml"
sha256sum "${TMP_DIR}/cdi-operator.yaml"
echo ""
echo -e "  Verify these match the release page before proceeding:"
echo -e "    https://github.com/kubevirt/kubevirt/releases/tag/${KUBEVIRT_VERSION}"
echo -e "    https://github.com/kubevirt/containerized-data-importer/releases/tag/${CDI_VERSION}"
echo -e "  ${YELLOW}────────────────────────────────────────────────────────────────${NC}"
echo ""

if ! $DRY_RUN; then
  read -r -p "  Manifests downloaded. Continue with apply? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ─── Step 3: Apply KubeVirt operator ──────────────────────────────────────────
echo ""
echo -e "${BOLD}[3/7] Applying KubeVirt operator ${KUBEVIRT_VERSION}${NC}"
apply "${TMP_DIR}/kubevirt-operator.yaml"
echo -e "  Waiting for virt-operator deployment to be ready..."
if ! $DRY_RUN; then
  kubectl -n kubevirt wait deployment/virt-operator --for=condition=Available --timeout=180s
fi
echo -e "  ${GREEN}✓${NC} virt-operator ready"

echo -e "  Applying KubeVirt CR from repo..."
apply "${REPO_ROOT}/infra/kubevirt/kubevirt-cr.yaml"
echo -e "  Waiting for KubeVirt to become Available (may take 2-3 minutes)..."
if ! $DRY_RUN; then
  kubectl wait kubevirt/kubevirt -n kubevirt --for=condition=Available --timeout=300s
fi
echo -e "  ${GREEN}✓${NC} KubeVirt CR Available"

# ─── Step 4: Apply CDI operator ───────────────────────────────────────────────
echo ""
echo -e "${BOLD}[4/7] Applying CDI operator ${CDI_VERSION}${NC}"
apply "${TMP_DIR}/cdi-operator.yaml"
echo -e "  Waiting for cdi-operator deployment to be ready..."
if ! $DRY_RUN; then
  kubectl -n cdi wait deployment/cdi-operator --for=condition=Available --timeout=180s
fi
echo -e "  ${GREEN}✓${NC} cdi-operator ready"

echo -e "  Applying CDI CR from repo..."
apply "${REPO_ROOT}/infra/cdi/cdi-cr.yaml"
echo -e "  Waiting for CDI to become Available..."
if ! $DRY_RUN; then
  kubectl wait cdi/cdi -n cdi --for=condition=Available --timeout=300s
fi
echo -e "  ${GREEN}✓${NC} CDI CR Available"

# ─── Step 5: Deploy local-path-provisioner ────────────────────────────────────
echo ""
echo -e "${BOLD}[5/7] Deploying local-path-provisioner${NC}"

echo -e "  Ensuring /opt/local-path-provisioner exists on k8s-worker03..."
if ! $DRY_RUN; then
  kubectl debug node/k8s-worker03 --image=busybox:stable --quiet \
    -- chroot /host sh -c "mkdir -p /opt/local-path-provisioner && chmod 777 /opt/local-path-provisioner" \
    2>/dev/null || \
  kubectl run prep-worker03-dir --rm -i --restart=Never \
    --image=busybox:stable \
    --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"k8s-worker03"},"hostPID":true,"hostNetwork":true,"tolerations":[{"operator":"Exists"}],"containers":[{"name":"prep","image":"busybox:stable","command":["mkdir","-p","/opt/local-path-provisioner"],"volumeMounts":[{"name":"host","mountPath":"/"}],"securityContext":{"privileged":true}}],"volumes":[{"name":"host","hostPath":{"path":"/"}}]}}' \
    -- echo "done" 2>/dev/null || \
  echo -e "  ${YELLOW}⚠${NC}  Could not auto-create directory. Run manually on k8s-worker03:"
  echo -e "     ssh admin@k8s-worker03 'sudo mkdir -p /opt/local-path-provisioner && sudo chmod 777 /opt/local-path-provisioner'"
fi

echo -e "  Applying local-path-provisioner manifests from repo..."
apply "${REPO_ROOT}/infra/local-path-provisioner/"
if ! $DRY_RUN; then
  kubectl -n local-path-storage wait deployment/local-path-provisioner \
    --for=condition=Available --timeout=120s
fi
echo -e "  ${GREEN}✓${NC} local-path-provisioner ready on k8s-worker03"

# Verify StorageClass exists
if ! $DRY_RUN; then
  if kubectl get sc local-path-vms &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} StorageClass local-path-vms available"
  else
    echo -e "  ${RED}✗${NC} StorageClass local-path-vms NOT found — check provisioner logs"
    kubectl logs -n local-path-storage -l app=local-path-provisioner --tail=20 || true
  fi
fi

# ─── Step 6: Apply vms manifests ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}[6/7] Applying VM workloads${NC}"
echo -e "  Applying vms namespace, network policies, and VM definition..."
apply "${REPO_ROOT}/vms/"
echo -e "  ${GREEN}✓${NC} VM manifests applied"

if ! $DRY_RUN; then
  echo ""
  echo -e "  Checking DataVolume import progress..."
  echo -e "  ${CYAN}  (Debian cloud image is ~500MB; import may take 2-5 minutes)${NC}"
  kubectl get dv -n vms 2>/dev/null || echo "  (No DataVolumes yet — VM is not yet started)"
fi

# ─── Step 7: Start VM and test ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[7/7] Starting the VM${NC}"
echo ""
echo -e "  The VM is created with ${BOLD}running: false${NC}. Start it when the DataVolume import completes."
echo ""
echo -e "  ${CYAN}Watch import progress:${NC}"
echo -e "    kubectl get dv -n vms -w"
echo -e "    kubectl get dv debian-bookworm-dv -n vms -o jsonpath='{.status.progress}'"
echo ""
echo -e "  ${CYAN}Once import shows 'Succeeded', start the VM:${NC}"
echo -e "    virtctl start debian-bookworm -n vms"
echo ""
echo -e "  ${CYAN}Watch VM boot:${NC}"
echo -e "    kubectl get vmi -n vms -w"
echo ""
echo -e "  ${CYAN}Access VM console (serial):${NC}"
echo -e "    virtctl console debian-bookworm -n vms"
echo ""
echo -e "  ${CYAN}SSH to VM via virtctl port-forward:${NC}"
echo -e "    virtctl port-forward vmi/debian-bookworm 2222:22 -n vms &"
echo -e "    ssh -p 2222 debian@localhost"
echo ""
echo -e "  ${CYAN}SSH directly via virtctl SSH:${NC}"
echo -e "    virtctl ssh debian@debian-bookworm -n vms"
echo ""
echo -e "  ${CYAN}Stop VM:${NC}"
echo -e "    virtctl stop debian-bookworm -n vms"
echo ""
echo -e "  ${CYAN}Install virtctl (Linux):${NC}"
echo -e "    VERSION=${KUBEVIRT_VERSION}"
echo -e "    curl -Lo virtctl https://github.com/kubevirt/kubevirt/releases/download/\${VERSION}/virtctl-\${VERSION}-linux-amd64"
echo -e "    chmod +x virtctl && sudo mv virtctl /usr/local/bin/"
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Bootstrap complete! Flux is still suspended.${NC}"
echo -e "${BOLD}  After testing, resume Flux:${NC}"
echo -e "${BOLD}    flux resume kustomization --all${NC}"
echo -e "${BOLD}  Flux will then manage KubeVirt CRs + vms manifests going forward.${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
