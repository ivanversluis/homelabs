# Wave 3: coordinated Arch Linux + Kubernetes

Status: **PREPARATION IMPLEMENTED — LIVE MUTATION NOT APPROVED**.

Wave 3 is the first lifecycle stage where host package state, reboot behavior, kubeadm ordering,
CNI/storage health and disruption policy interact. Preparation is therefore intentionally
separate from execution.

## Current live baseline

Latest operator evidence before this preparation:

- k8s-master01: Kubernetes/kubelet packages v1.35.1, kernel 6.18.13.arch1-1,
  containerd 2.2.1-1.
- k8s-worker01/02/03: Kubernetes/kubelet packages v1.35.2, kernel 6.19.8.arch1-1,
  containerd 2.2.2-1.
- all four nodes depend on the standalone control-tower Python because system Python is not
  currently functional.
- Calico v3.32.1 is healthy after Wave 2.
- Longhorn manager v1.12.1 is healthy after Wave 1.
- Longhorn node-drain policy is `block-if-contains-last-replica`.
- multiple Longhorn instance-manager PDBs currently report `disruptionsAllowed=0`.
- there is exactly one control-plane node.
- authoritative Semaphore readiness returned `READY WITH ACCEPTED EXCEPTIONS` with no blockers.

## Preparation playbook

Run from Semaphore:

```text
playbook=playbooks/60-wave3-preflight.yml
limit=k8s_homelab
```

The playbook is read-only and must inspect all four nodes. It does not cordon, drain, update
packages, run `kubeadm upgrade apply/node`, restart services or reboot.

It collects:

- installed and candidate Arch package versions;
- pacman database consistency;
- system Python binary/package/dynamic-linker diagnostics;
- kernel, cgroup, swap, kubeadm/kubelet/kubectl, containerd/runc and critical services;
- running Kubernetes control-plane/kube-proxy images;
- kubeadm ClusterConfiguration and `kubeadm upgrade plan`;
- Calico/TigeraStatus baseline;
- Longhorn manager/volume/node/drain/PDB state;
- Flux reconciliation state.

## Target-selection rule

`v1.36.4` is currently recorded only as a candidate for the planning window, not an automatic
target. Before any live mutation, confirm the target from the actual Arch repository and
upstream Kubernetes/add-on support matrices. Do not jump directly to Kubernetes 1.37 while the
current Calico/Longhorn baseline has only been validated through the intended 1.36 path.

## Ordering

Two flows remain distinct:

### Arch-only maintenance

```text
worker canary -> remaining workers -> control plane
```

### kubeadm minor-version upgrade

```text
control plane -> worker01/02/03 one at a time
```

A combined maintenance window must explicitly reconcile these constraints instead of treating
all nodes as one loop.

## Safety properties for future mutation

Every mutating playbook must use:

```yaml
serial: 1
any_errors_fatal: true
max_fail_percentage: 0
```

Never bypass PDBs by default, never use `kubectl drain --disable-eviction` as a routine option,
never run `pacman -Syu` concurrently on multiple nodes, and never use partial upgrades such as
`pacman -Sy <package>`.

Before live execution, re-confirm etcd recovery, Longhorn backup/volume health, Vault/Semaphore
control-tower recovery and the independent admin break-glass route.

## Approval gate

No Wave 3 mutating playbook should be created or executed until the new preflight output has
been reviewed and an explicit operator approval identifies:

1. exact Arch package target state;
2. exact Kubernetes target version and supported upgrade path;
3. system-Python repair mechanism;
4. drain strategy for current Longhorn PDB/replica placement;
5. rollback/recovery expectations for the single control-plane node.
