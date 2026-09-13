# KubeVirt - Virtual Machines on Kubernetes

## Overview

KubeVirt extends Kubernetes with virtual-machine support. VMs are declared as Kubernetes `VirtualMachine` resources and scheduled on nodes with KVM hardware virtualization. CDI (Containerized Data Importer) handles importing, cloning, and managing VM disk images as PVCs.

The repository intentionally separates the **virtualization platform** from **VM workloads**:

```text
platform/virtualization/kubevirt/   # KubeVirt platform/controller configuration
platform/virtualization/cdi/        # CDI platform/controller configuration
platform/storage/local-path-provisioner/
                                    # node-local VM storage capability
workloads/vms/                      # VirtualMachine workloads
```

The current VM lab runs workloads on `k8s-worker03`, which provides KVM and local NVMe-backed storage.

## Component map

| Component | Version | Namespace | Role |
|---|---|---|---|
| KubeVirt operator | v1.8.2 | `kubevirt` | Manages virt-api, virt-controller, virt-handler |
| CDI operator | v1.65.0 | `cdi` | Imports/clones VM disk images into PVCs |
| local-path-provisioner | v0.0.36 | `local-path-storage` | Dynamic hostPath storage for the VM lab |
| VM workloads | - | `vms` | `VirtualMachine` resources |

## Storage architecture

```text
VM disk PVC
  -> StorageClass: local-path
     -> rancher.io/local-path provisioner
        -> hostPath on k8s-worker03
```

`WaitForFirstConsumer` plus CDI `spec.workload.nodeSelector` in `platform/virtualization/cdi/cdi-cr.yaml` keeps the importer and VM workload aligned with the local-storage node.

## Initial bootstrap

The KubeVirt and CDI operator bundles are bootstrapped once because the CRDs/operators must exist before Flux can reconcile their custom resources.

```bash
./scripts/deploy-kubevirt-local.sh --dry-run
./scripts/deploy-kubevirt-local.sh
```

The script:

1. performs pre-flight checks;
2. suspends Flux unless explicitly skipped;
3. downloads pinned KubeVirt/CDI operator manifests for review;
4. applies the operators and waits for readiness;
5. applies the CRs from `platform/virtualization/`;
6. verifies/deploys the local-path storage capability from `platform/storage/local-path-provisioner/`;
7. applies the existing `workloads/vms/` workload manifests.

## Flux ownership

After bootstrap, Flux manages:

- `platform/virtualization/kubevirt/` - KubeVirt namespace and KubeVirt CR/configuration;
- `platform/virtualization/cdi/` - CDI namespace and CDI CR/configuration;
- `platform/storage/local-path-provisioner/` - declarative/reference storage manifests according to the documented bootstrap model;
- `workloads/vms/` - VM workload namespace, policies, Services, and `VirtualMachine` resources.

The dedicated platform reconciliation chain is:

```text
kubevirt Flux Kustomization
  -> cdi Flux Kustomization (dependsOn: kubevirt)
     -> vms Flux Kustomization
```

Wave 2 changes only the repository path for VM workloads. `Kustomization/vms` remains the same live Flux owner and retains its inventory.

## VM lifecycle

```bash
kubectl get dv -n vms -w
virtctl start debian-bookworm -n vms
kubectl get vmi -n vms -w
```

Console and SSH options:

```bash
virtctl console debian-bookworm -n vms

LAUNCHER=$(kubectl get pod -n vms -l kubevirt.io=virt-launcher -o name | head -1 | sed 's|pod/||')
kubectl port-forward -n vms pod/$LAUNCHER 2222:22 &
ssh -i ~/.ssh/id_ed25519 -p 2222 debian@localhost

virtctl ssh debian@vm/debian-bookworm/vms
```

Stop/restart:

```bash
virtctl stop debian-bookworm -n vms
virtctl start debian-bookworm -n vms
virtctl restart debian-bookworm -n vms
```

Hardware-shaped changes such as interfaces, disks, CPU/memory topology, or masquerade port declarations require a VM restart because they are not live-reconciled into an existing VMI.

## KubeVirt networking

The VM pod uses KubeVirt masquerade binding. Any guest port that must be reachable through the pod must be declared on the interface:

```yaml
interfaces:
  - name: default
    masquerade: {}
    ports:
      - name: ssh
        port: 22
        protocol: TCP
```

A missing masquerade `ports` entry can produce a timeout even when MetalLB, the Kubernetes Service, endpoints, and NetworkPolicy all appear correct. Restart the VM after changing this section.

## Network policies

| Namespace | Policy model | Notes |
|---|---|---|
| `kubevirt` | excluded from global default deny | operator/webhook traffic requires broad platform communication |
| `cdi` | excluded from global default deny | importer/operator communication |
| `local-path-storage` | explicitly controlled | DNS, same namespace, API-server access as required |
| `vms` | deny by default + explicit allows | workload DNS/Internet/SSH rules |

The global baseline is maintained under `platform/networking/network-policies/`.

CDI importer pods for a DataVolume run in the `vms` namespace, so image-download egress is governed by the workload policy in `workloads/vms/vms-netpol.yaml`.

## Troubleshooting

### VM stuck scheduling

```bash
kubectl describe vmi debian-bookworm -n vms
```

Check node readiness, KVM availability, node labels, and capacity.

### DataVolume pending/importing

```bash
kubectl describe dv debian-bookworm-dv -n vms
kubectl get pvc -n vms
kubectl get pods -n vms
```

Check local-path-provisioner readiness, available node storage, CDI readiness, DNS, and HTTPS egress from the `vms` namespace.

### LoadBalancer reachable at L2 but TCP times out

If endpoints and MetalLB advertisement are healthy, verify the KubeVirt masquerade interface contains the destination port. The pod-level NAT silently drops undeclared inbound ports.

## Adding VMs

VMs are workload definitions under `workloads/vms/`:

1. add `workloads/vms/<name>-vm.yaml`;
2. update VM/DataVolume names and node/storage settings;
3. add it to `workloads/vms/kustomization.yaml`;
4. let the existing `vms` Flux Kustomization reconcile it or use the documented local bootstrap/test flow.

## References

- KubeVirt documentation: https://kubevirt.io/user-guide/
- CDI DataVolumes: https://github.com/kubevirt/containerized-data-importer/blob/main/doc/datavolumes.md
- local-path-provisioner: https://github.com/rancher/local-path-provisioner
