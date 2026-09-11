# Wave 3: coordinated Arch Linux + Kubernetes

Status: **LIVE PREFLIGHT COMPLETE — KUBEADM CONFIG REPAIRED — LONGHORN DRAIN READINESS UNDER REVIEW**.

Wave 3 is the first lifecycle stage where host package state, reboot behavior, kubeadm ordering,
CNI/storage health and disruption policy interact. Preparation and execution are therefore
intentionally separated.

## Live preflight evidence — Semaphore task 45

`playbooks/60-wave3-preflight.yml` completed successfully across all four nodes through the
Semaphore -> Vault -> ephemeral SSH certificate -> Ansible control-tower path. No package,
Kubernetes, drain, reboot, or service mutation was performed.

Observed baseline:

- `k8s-master01`: kernel `6.18.13-arch1-1`, kubeadm/kubelet/kubectl `1.35.1`, containerd `2.2.1`, runc `1.4.0`.
- `k8s-worker01/02/03`: kernel `6.19.8-arch1-1`, kubeadm/kubelet/kubectl `1.35.2`, containerd `2.2.2`, runc `1.4.1`.
- system Python is not merely broken: the `python` package and `/usr/bin/python3` are absent on all four nodes. The standalone control-tower Python remains the safe automation interpreter until a full Arch synchronization restores system Python.
- the existing pacman sync database reports a large pending Arch update set including glibc 2.44, kernel 7.2.4, systemd 261.x, containerd 2.3.5, runc 1.5.1 and Kubernetes 1.36.4. Because `checkupdates` is unavailable, this evidence may be stale and is not by itself approval to mutate.
- Kubernetes reports four Ready nodes. Running control-plane and kube-proxy images remain `v1.35.0`; kubelet packages are newer (`1.35.1`/`1.35.2`).
- `kubeadm upgrade plan` sees cluster version `1.35.0` and, with current kubeadm `1.35.1`, offers the latest patch in that minor (`v1.35.8`).
- Calico `v3.32.1` is healthy and all TigeraStatus objects are Available, not Progressing or Degraded.
- Longhorn manager `v1.12.1` is present; all listed V1 volumes are healthy. Node drain policy remains `block-if-contains-last-replica` and several instance-manager PDBs have `disruptionsAllowed=0`.
- Flux Kustomizations/HelmReleases reported Ready.

## Kubeadm ConfigMap repair — Semaphore tasks 47/48

Task 47 proved the live `ClusterConfiguration` contained one valid `apiServer.extraArgs` block
for Authentik OIDC plus a duplicate empty `apiServer: {}` mapping. The dedicated repair playbook
`62-wave3-kubeadm-config-repair.yml` removed only the empty duplicate, preserved all OIDC flags,
created a protected backup, validated the corrected v1beta4 configuration, uploaded it through
kubeadm, and proved the kube-apiserver static manifest checksum was unchanged.

Task 48 completed with:

```text
WAVE 3 KUBEADM CONFIG REPAIR: SUCCESS
```

Post-repair `kubeadm upgrade plan` parses cleanly. Cluster version remains `1.35.0`, current
kubeadm remains `v1.35.1`, and the current 1.35-series target remains `v1.35.8` until kubeadm is
deliberately advanced for the 1.36 minor-upgrade path.

## Execution gate — Semaphore task 50

The rerun of `61-wave3-execution-gate.yml` proved:

- kubeadm configuration parsing is clean;
- Calico v3.32.1 baseline is healthy;
- Longhorn v1.12.1 baseline and volume health are healthy;
- Flux active resources have no blockers and no suspended exceptions;
- all three worker drain simulations reach workload eviction planning but stop on Longhorn
  `instance-manager-*` PodDisruptionBudgets with `Cannot evict pod as it would violate the pod's disruption budget`.

The same pattern occurs on worker01, worker02 and worker03. No workload was actually evicted
because the command used `--dry-run=server`.

This is not treated as permission to bypass the PDBs. It is also not sufficient evidence by
itself that a real maintenance cordon cannot succeed. Longhorn has controller behavior that is
specifically tied to a node becoming cordoned/unschedulable, while `kubectl drain --dry-run=server`
does not leave that node state persisted for controllers to reconcile against.

Therefore Wave 3 remains blocked from real drain/upgrade mutation until Longhorn-aware drain
readiness is understood.

Run the new read-only evidence playbook:

```text
playbook=playbooks/63-wave3-longhorn-drain-readiness.yml
limit=k8s-master01
```

It records Longhorn drain-related settings, node scheduling/eviction state, volume and replica
placement, instance-manager placement/state, PDB state and per-worker Longhorn pod placement.
It performs no cordon, drain, eviction, patch, restart or reboot.

If that evidence is healthy, the next step is a separately reviewed reversible live-cordon probe
on one worker only. That future probe must cordon one worker, wait for Longhorn reconciliation,
run a drain dry-run while the node is actually cordoned, perform no real workload eviction, and
uncordon in an Ansible `always` path regardless of success/failure.

Do not use `--disable-eviction`, forced pod deletion, or weaker Longhorn node-drain policy as a
workaround.

## Target-selection rule

Kubernetes `v1.36.4` is the current Arch-repository candidate seen by the preflight and remains
the intended minor target, but it is not yet approved for execution. The current kubeadm binary
is still 1.35.x, so its plan correctly resolves only the 1.35 patch line. The supported kubeadm
minor-upgrade sequence requires upgrading the kubeadm binary first, re-running `kubeadm upgrade
plan`, then applying the control-plane upgrade before worker kubelets move to the new minor.

Do not jump to Kubernetes 1.37. Current Wave 1/2 add-on baselines were selected for the 1.36
maintenance path.

## Arch/Kubernetes sequencing model

Arch is rolling release and does not support arbitrary partial system upgrades. Kubernetes,
however, requires kubeadm/control-plane-first ordering for a minor upgrade and kubelets must not
be advanced ahead of the API server. Wave 3 must therefore keep these concerns explicit rather
than running one blind `pacman -Syu` loop.

Planned stages after the Longhorn drain gate is clean:

1. refresh/reconfirm package targets without creating a partial-upgrade state;
2. perform worker-canary Arch host maintenance while holding Kubernetes packages at the current minor;
3. validate/reboot that worker and repeat workers one at a time;
4. perform equivalent Arch host maintenance on the single control-plane node with explicit downtime/recovery gate;
5. upgrade kubeadm on the control plane to the approved 1.36 patch, re-run `kubeadm upgrade plan`, then `kubeadm upgrade apply`;
6. upgrade/restart the control-plane kubelet/kubectl and validate API server, etcd, Calico, Longhorn and Flux;
7. upgrade workers to the same Kubernetes patch one at a time using kubeadm node semantics, kubelet restart and full post-node health gates;
8. rerun `50-maintenance-readiness.yml` against `k8s_homelab` before Wave 4.

## Safety properties

Every mutating playbook must use:

```yaml
serial: 1
any_errors_fatal: true
max_fail_percentage: 0
```

Never bypass PDBs by default, never use `kubectl drain --disable-eviction` as a routine option,
never run `pacman -Syu` concurrently, and never use `pacman -Sy <package>`.

The single control-plane node has no HA fallback. Before mutation re-confirm etcd recovery,
Longhorn backups/volume health, Vault/Semaphore recovery and the independent admin break-glass
route.
