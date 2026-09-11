# Wave 2: Calico

Baseline: Semaphore task 43 returned READY WITH ACCEPTED EXCEPTIONS, no blockers.
Calico v3.29.1 / Tigera v1.36.2 was adopted into Flux at ba8f1ad; the operator
and Installation already existed from bootstrap. User supplied healthy TigeraStatus
after adoption. Target approved in this conversation: Calico v3.32.1 / Tigera v1.42.3.

The official OSS upgrade guide covers v3.15+ to v3.32. Use its operator procedure,
not the Calico Enterprise upgrade policy. Kubernetes nodes currently run 1.35.x.
Source, checksums, and split-file validation are documented in the vendor README.

## Rollout and acceptance

Flux first establishes the 32 CRDs in `calico-crds`, then updates `calico`.
The existing Installation is unchanged; keep iptables, BGP, VXLANCrossSubnet,
10.244.0.0/16, firstFound autodetection and maxUnavailable=1.
Do not enable eBPF, native v3 migration, Goldmane or Whisker in this wave.

On k8s-master01, monitor:

```bash
kubectl -n flux-system get kustomizations calico-crds calico
kubectl -n tigera-operator rollout status deployment/tigera-operator --timeout=10m
kubectl -n calico-system rollout status daemonset/calico-node --timeout=10m
kubectl get tigerastatus
kubectl get installation.operator.tigera.io default -o jsonpath='{.status.calicoVersion}{"\n"}'
kubectl -n calico-system get pods -o wide
kubectl get nodes
```

Acceptance requires v3.32.1, Ready Flux resources, all TigeraStatus objects available,
none progressing/degraded, four Ready nodes, and ready Calico/CSI/API-server pods.
Test pod DNS, cross-node pod/service traffic, ingress/OIDC, Synology backup reachability,
and representative applications. Run Semaphore `playbooks/50-maintenance-readiness.yml`
with limit `k8s_homelab` and require a non-blocking verdict. Running pods alone do not
prove network policy correctness. Use v3.32.1 calicoctl if needed; avoid older clients.

If rollout fails, stop further maintenance and collect the failing Flux resource,
TigeraStatus and operator logs. Do not delete CRDs or force a CNI reinstall. A Git
revert does not guarantee a safe downgrade after schemas or controllers have changed.
Keep admin SSH/console access available while investigating.

## Remaining lifecycle work

Wave 2 is not marked complete until live acceptance evidence is supplied.
Then prepare Wave 3 Arch/Kubernetes: repair system Python, review package/kernel and
Kubernetes compatibility, confirm recoverable etcd/volume backups, inspect active
Longhorn instance-manager references and PDBs, and plan one node at a time. Old
instance-manager images may still host live processes despite upgraded engine images;
never classify them as disposable solely by age or engine version.
Ordinary OS maintenance begins with a worker canary; kubeadm minor upgrades require
control-plane-first ordering. Avoid partial Arch upgrades (`pacman -Sy package`).
Wave 4 platform and Wave 5 applications follow separate preparation/approval gates.
