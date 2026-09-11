# Wave 2: Calico

Status: **COMPLETE**.

Baseline: Semaphore task 43 returned READY WITH ACCEPTED EXCEPTIONS, no blockers.
Calico v3.29.1 / Tigera v1.36.2 was adopted into Flux at ba8f1ad; the operator and
Installation already existed from bootstrap. Wave 2 upgraded the cluster to Calico v3.32.1 /
Tigera v1.42.3 using the vendored, checksum-recorded operator manifests and split CRD/runtime
Flux ordering.

## Live acceptance evidence

Operator-supplied evidence after rollout confirms:

- Flux Kustomization `calico-crds`: Ready=True, revision `714685bd64efa754f648a92a4e2bd85bc97dfc09`.
- Flux Kustomization `calico`: Ready=True, same revision.
- `Installation/default` reports `v3.32.1`.
- TigeraStatus `apiserver`, `calico`, `ippools`, and `tiers`: Available=True,
  Progressing=False, Degraded=False.
- all four Kubernetes nodes are Ready.
- `calico-node`, `calico-kube-controllers`, `calico-typha`, `calico-apiserver`, and CSI node
  driver pods are Running/Ready across the cluster.
- post-upgrade Semaphore `playbooks/50-maintenance-readiness.yml` with
  `limit=k8s_homelab` completed successfully and returned `READY WITH ACCEPTED EXCEPTIONS`,
  with `Blocker IDs: []`.
- the readiness report confirmed the live Calico baseline as `v3.32.1` and Longhorn baseline
  as `v1.12.1`.

Running pods alone do not prove every dataplane policy. Representative DNS, cross-node
pod/service, ingress/OIDC, tunnel/LAN, and existing Zero Trust NetworkPolicy validation should
continue to be exercised as part of normal regression testing. No further Calico mutation is
part of Wave 2.

## Preserved design

The existing Installation remains on the established networking model: iptables dataplane,
BGP/VXLAN cross-subnet behavior, `10.244.0.0/16`, first-found node address autodetection and
controlled rolling availability. Wave 2 did not intentionally enable eBPF, native v3 migration,
Goldmane, or Whisker.

## Next lifecycle stage

Wave 3 is coordinated Arch Linux + Kubernetes maintenance. It must first repair/understand the
system-Python partial-upgrade state, reconcile package and running Kubernetes versions, inspect
Longhorn drain/PDB constraints, confirm backups/recovery, and determine a supported target.

Ordinary Arch-only maintenance uses a worker canary. A kubeadm minor-version upgrade uses
control-plane-first ordering and workers one at a time. Never use partial Arch upgrades such as
`pacman -Sy <package>`.
