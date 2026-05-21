# KubeVirt — Virtual Machines on Kubernetes

## Overview

KubeVirt extends Kubernetes with virtual machine (VM) support. VMs are
declared as standard Kubernetes objects (`VirtualMachine` CRDs) and scheduled
on nodes that have KVM hardware virtualization enabled. CDI (Containerized Data
Importer) handles importing, cloning and managing VM disk images as PVCs.

This deployment runs VMs exclusively on **k8s-worker03**, which has KVM
enabled and hosts local NVMe-backed storage for VM disks.

---

## Component Map

| Component | Version | Namespace | Role |
|---|---|---|---|
| KubeVirt operator | v1.8.2 | `kubevirt` | Manages virt-api, virt-controller, virt-handler DaemonSet |
| CDI operator | v1.65.0 | `cdi` | Imports/clones VM disk images into PVCs |
| local-path-provisioner | v0.0.36 | `local-path-storage` | Dynamic hostPath StorageClass on k8s-worker03 |
| VM workloads | — | `vms` | VirtualMachine CRDs |

### KubeVirt Internal Pods

| Pod | Role |
|---|---|
| `virt-operator` | Deploys and reconciles all other virt-* components |
| `virt-api` | Kubernetes API extension for VM CRDs; exposes webhooks |
| `virt-controller` | Reconciles VM → VMI lifecycle |
| `virt-handler` | DaemonSet on KVM nodes; manages QEMU/KVM process per VMI |

---

## Storage Architecture

```
VM disk (20Gi PVC)
  └── StorageClass: local-path   (pre-existing rancher/local-path-provisioner v0.0.36)
        └── Provisioner: rancher.io/local-path
              └── hostPath on k8s-worker03: /opt/local-path-provisioner/<pvc-name>/
```

`WaitForFirstConsumer` binding + CDI `spec.workload.nodeSelector` (set in `infra/cdi/cdi-cr.yaml`)
ensure both the CDI importer pod and the VM pod are pinned to k8s-worker03.

---

## Initial Deployment (Local-First)

### Prerequisites

1. `k8s-worker03` has KVM enabled:
   ```bash
   # Verify (already done)
   ssh admin@k8s-worker03 'lsmod | grep kvm_intel'
   ```

2. Install `virtctl` on your workstation:
   ```bash
   VERSION=v1.8.2
   curl -Lo virtctl https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/virtctl-${VERSION}-linux-amd64
   chmod +x virtctl && sudo mv virtctl /usr/local/bin/
   ```

### Bootstrap Script

```bash
# Dry-run first
./scripts/deploy-kubevirt-local.sh --dry-run

# Full bootstrap (suspends Flux, downloads operators, applies everything)
./scripts/deploy-kubevirt-local.sh
```

The script:
1. Suspends all Flux Kustomizations (prevents reconciliation conflicts)
2. Downloads KubeVirt and CDI operator manifests (pinned versions)
3. Prints SHA256 checksums for manual review before applying
4. Applies operators and waits for each to become Ready
5. Deploys local-path-provisioner on k8s-worker03
6. Applies the `vms/` manifests (namespace, network policies, VM definition)
7. Prints next steps for starting and accessing the VM

---

## VM Lifecycle

### Start VM (triggers cloud-init + DataVolume import on first start)

```bash
# Watch DataVolume import (download + convert Debian cloud image ~500MB)
kubectl get dv -n vms -w

# Once DataVolume shows Succeeded, start the VM
virtctl start debian-bookworm -n vms

# Watch VMI come up
kubectl get vmi -n vms -w
```

### Connect to VM

```bash
# Serial console (no SSH needed, works from day 1)
virtctl console debian-bookworm -n vms

# SSH via kubectl port-forward on the virt-launcher pod (recommended)
# Note: virtctl port-forward may hang at banner exchange due to network policy interaction;
#       kubectl port-forward on the virt-launcher pod is the reliable alternative.
LAUNCHER=$(kubectl get pod -n vms -l kubevirt.io=virt-launcher -o name | head -1 | sed 's|pod/||')
kubectl port-forward -n vms pod/$LAUNCHER 2222:22 &
ssh -i ~/.ssh/id_ed25519 -p 2222 debian@localhost

# SSH via virtctl SSH (alternative — uses guest agent authorized-key injection)
virtctl ssh debian@vm/debian-bookworm/vms
```

### Stop / Restart

```bash
virtctl stop   debian-bookworm -n vms   # graceful ACPI shutdown
virtctl start  debian-bookworm -n vms   # start
virtctl restart debian-bookworm -n vms  # graceful restart
```

### Pause / Unpause (freeze VM without losing state)

```bash
virtctl pause   vmi/debian-bookworm -n vms
virtctl unpause vmi/debian-bookworm -n vms
```

---

## Cloud-Init Configuration

The VM uses `cloudInitNoCloud` with inline user-data. The SSH key is set in
[vms/debian-bookworm-vm.yaml](../vms/debian-bookworm-vm.yaml) under `ssh_authorized_keys`.

Cloud-init only runs on the **first boot** after provisioning. To inject an SSH key
into an **already-running VM** without rebooting:

```bash
# Inject key via QEMU guest agent (no restart needed)
LAUNCHER=$(kubectl get pod -n vms -l kubevirt.io=virt-launcher -o name | head -1)
PUBKEY=$(cat ~/.ssh/id_ed25519.pub)
kubectl exec -n vms $LAUNCHER -- virsh qemu-agent-command vms_debian-bookworm \
  "{\"execute\":\"guest-ssh-add-authorized-keys\",\"arguments\":{\"username\":\"debian\",\"keys\":[\"${PUBKEY}\"]}}"
```

To re-run cloud-init (e.g. to change hostname or packages), delete the DataVolume and re-apply:
```bash
kubectl delete vm debian-bookworm -n vms
kubectl delete dv debian-bookworm-dv -n vms   # deletes the disk!
kubectl apply -k vms/
virtctl start debian-bookworm -n vms
```

---

## Flux GitOps Integration

After successful local testing, resume Flux to take over:

```bash
flux resume kustomization --all
```

Flux manages:
- `infra/kubevirt/` → KubeVirt namespace + CR + network policies
- `infra/cdi/` → CDI namespace + CR + network policies
- `infra/local-path-provisioner/` → provisioner + StorageClass + network policies
- `vms/` → vms namespace + network policies + VirtualMachine CRDs

The KubeVirt and CDI **operator manifests** (CRDs, RBAC, Deployments) must be
bootstrapped manually once per cluster — Flux manages only the CRs and our
configuration on top.

### Dependency Chain

```
kubevirt Flux Kustomization
  └── cdi Flux Kustomization (dependsOn: kubevirt)
        └── vms Flux Kustomization (dependsOn: kubevirt, cdi)
```

---

## Network Policies

| Namespace | Default Deny | Key Policies |
|---|---|---|
| `kubevirt` | Excluded from GlobalNetworkPolicy (operator-level access needed) | Same-ns, API server egress, webhook ingress |
| `cdi` | Excluded from GlobalNetworkPolicy | Same-ns, API server, HTTPS egress, upload proxy ingress |
| `local-path-storage` | Enforced (per global deny) | DNS, same-ns, API server egress only |
| `vms` | Enforced (per global deny) | DNS, HTTPS+HTTP egress, SSH ingress from LAN |

CDI importer pods run **inside the `vms` namespace** (same namespace as the
DataVolume). They need HTTPS egress to download cloud images — this is covered
by `allow-egress-internet-https` in [vms/vms-netpol.yaml](../vms/vms-netpol.yaml).

---

## Troubleshooting

### VM stuck in `Scheduling` state

```bash
kubectl describe vmi debian-bookworm -n vms
# Look for: "failed to schedule pod" or "insufficient resources"
```

Common causes:
- `k8s-worker03` not found or NotReady: `kubectl get node k8s-worker03`
- `/dev/kvm` missing on node (re-run `prepare-kvm.sh`)
- Node doesn't have `kubernetes.io/hostname: k8s-worker03` label

### DataVolume stuck in `Pending`

```bash
kubectl describe dv debian-bookworm-dv -n vms
kubectl get pvc -n vms
```

Common causes:
- `local-path-provisioner` not running on worker03: `kubectl get pods -n local-path-storage`
- Directory `/opt/local-path-provisioner` missing on worker03
- CDI not ready: `kubectl get cdi -A`

### DataVolume stuck in `Importing`

```bash
# Find the importer pod
kubectl get pods -n vms
kubectl logs -n vms <importer-pod-name>
```

Common causes:
- Network policy blocking HTTPS egress from vms namespace
- DNS not resolving `cloud.debian.org`
- Disk space insufficient on worker03 (`df -h /opt/local-path-provisioner`)

### VM starts but cloud-init doesn't run

```bash
# Check serial console
virtctl console debian-bookworm -n vms

# Check cloud-init logs inside VM
journalctl -u cloud-init
cloud-init status --long
```

### Reset VM (delete disk + re-import)

```bash
virtctl stop debian-bookworm -n vms
kubectl delete vm debian-bookworm -n vms          # deletes VM + DataVolume
kubectl apply -f vms/debian-bookworm-vm.yaml      # re-creates with fresh import
```

---

## Adding New VMs

1. Copy `vms/debian-bookworm-vm.yaml` and rename to `vms/<name>-vm.yaml`
2. Update `metadata.name`, `spec.dataVolumeTemplates[0].metadata.name`, and `spec.template.spec.volumes[0].dataVolume.name`
3. Keep `nodeSelector: kubernetes.io/hostname: k8s-worker03` for local storage
4. Set `storageClassName: local-path-vms`
5. Add the new file to `vms/kustomization.yaml`
6. Apply: `kubectl apply -f vms/` or let Flux reconcile

---

## References

- [KubeVirt Documentation](https://kubevirt.io/user-guide/)
- [CDI Documentation](https://github.com/kubevirt/containerized-data-importer/blob/main/doc/datavolumes.md)
- [local-path-provisioner](https://github.com/rancher/local-path-provisioner)
- [virtctl releases](https://github.com/kubevirt/kubevirt/releases/tag/v1.8.2)
- [Debian Cloud Images](https://cloud.debian.org/images/cloud/bookworm/latest/)
