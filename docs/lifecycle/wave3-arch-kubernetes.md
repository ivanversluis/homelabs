# Wave 3: coordinated Arch Linux + Kubernetes

Status: **LIVE PREFLIGHT COMPLETE — KUBEADM CONFIG REPAIRED — LONGHORN ENGINE AUDIT COMPLETE — LIVE DRAIN CANARY PREPARED BUT NOT APPROVED**.

Wave 3 is the first lifecycle stage where host package state, reboot behavior, kubeadm ordering,
CNI/storage health and disruption policy interact. Preparation and execution are intentionally
separated.

## Live preflight evidence — Semaphore task 45

`playbooks/60-wave3-preflight.yml` completed successfully across all four nodes through the
Semaphore -> Vault -> ephemeral SSH certificate -> Ansible control-tower path. No package,
Kubernetes, drain, reboot, or service mutation was performed.

Observed baseline:

- `k8s-master01`: kernel `6.18.13-arch1-1`, kubeadm/kubelet/kubectl `1.35.1`, containerd `2.2.1`, runc `1.4.0`.
- `k8s-worker01/02/03`: kernel `6.19.8-arch1-1`, kubeadm/kubelet/kubectl `1.35.2`, containerd `2.2.2`, runc `1.4.1`.
- system Python is absent on all four nodes; the standalone control-tower Python remains the safe automation interpreter until a full Arch synchronization restores system Python.
- the existing pacman sync database reports a large pending Arch update set including glibc 2.44, kernel 7.2.4, systemd 261.x, containerd 2.3.5, runc 1.5.1 and Kubernetes 1.36.4. Because `checkupdates` is unavailable, this evidence may be stale and is not by itself approval to mutate.
- Kubernetes reports four Ready nodes. Running control-plane and kube-proxy images remain `v1.35.0`; kubelet packages are newer (`1.35.1`/`1.35.2`).
- `kubeadm upgrade plan` sees cluster version `1.35.0` and, with current kubeadm `1.35.1`, offers the latest patch in that minor (`v1.35.8`).
- Calico `v3.32.1` is healthy and all TigeraStatus objects are Available, not Progressing or Degraded.
- Longhorn manager `v1.12.1` is present; all listed V1 volumes are healthy. Node drain policy remains `block-if-contains-last-replica`.
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
- Longhorn v1.12.1 manager/volume health baseline is healthy;
- Flux active resources have no blockers and no suspended exceptions;
- all three worker drain simulations reach workload eviction planning but stop on Longhorn
  `instance-manager-*` PodDisruptionBudgets with `Cannot evict pod as it would violate the pod's disruption budget`.

No workload was actually evicted because the command used `--dry-run=server`.

## Longhorn-aware drain evidence — Semaphore task 51

`playbooks/63-wave3-longhorn-drain-readiness.yml` completed successfully and established:

- all workers Ready;
- `node-drain-policy=block-if-contains-last-replica`;
- `detach-manually-attached-volumes-when-cordoned=false`;
- `disable-scheduling-on-cordoned-node=true`;
- all Longhorn nodes allow scheduling and have no eviction requested;
- all listed volumes are attached and healthy with two replicas;
- replicas are distributed across the worker set;
- every instance-manager PDB has `minAvailable=1` and `disruptionsAllowed=0`;
- each worker runs two AIO instance managers: one `v1.12.1` and one `v1.11.0-hotfix-1`.

The mixed instance-manager state required an engine/replica mapping audit before attempting any
live cordon or drain.

## Longhorn engine-image audit — Semaphore task 52

`playbooks/64-wave3-longhorn-engine-audit.yml` completed successfully and resolved the ambiguity.

Observed state:

- Longhorn manager image is `docker.io/longhornio/longhorn-manager:v1.12.1`;
- default engine image is `docker.io/longhornio/longhorn-engine:v1.12.1`;
- every listed volume has both desired and current engine image `v1.12.1`;
- every listed engine has desired and current engine image `v1.12.1`;
- every listed replica uses `v1.12.1`;
- the old-image scan returned only the section headers `OLD_VOLUMES`, `OLD_ENGINES`, and
  `OLD_REPLICAS`, with no resources below them;
- the only EngineImage object is the deployed v1.12.1 image;
- replicas run in the v1.12.1 instance managers;
- active engines still run inside the old v1.11.0-hotfix-1 instance managers, one old instance
  manager per worker.

Therefore Wave 1 engine migration itself is complete. The remaining v1.11 instance managers are
runtime leftovers hosting already-upgraded v1.12.1 engine processes for currently attached
volumes. They cannot become empty during a server-side drain dry-run because workload pods are
not actually evicted, so the attached volumes never detach or move. This explains why Task 50
repeatedly hit those instance-manager PDBs despite all volume/engine/replica images being current.

Do not delete the old instance-manager pods manually and do not weaken the Longhorn drain policy.

## Prepared live worker drain canary — approval required

A dedicated canary is now prepared as:

```text
playbook=playbooks/65-wave3-worker-drain-canary.yml
limit=k8s-master01
```

It is committed with `wave3_canary_approved: false` and therefore stops before mutation. A later
explicit operator approval must activate it in Git.

The canary is intentionally restricted to `k8s-worker02`. Task 50 showed no Semaphore/Vault
workload on that node, and the role re-checks that condition immediately before mutation.

Once explicitly activated, it will:

1. revalidate the worker, Longhorn policy, manager/default-engine image, volume health and absence
   of v1.11 volume/engine/replica image references;
2. refuse to continue if Semaphore or Vault workloads are on the target;
3. record pre-drain instance-manager/PDB/workload evidence;
4. persist a real cordon on `k8s-worker02`;
5. perform a real Kubernetes drain with ordinary eviction/PDB semantics;
6. never use `--disable-eviction`, `--force`, forced pod deletion, or a weaker Longhorn policy;
7. wait for all Longhorn volumes to return healthy and record post-drain state;
8. always uncordon the node in an Ansible `always` block.

This is a disruptive canary: application pods on worker02 will be evicted and rescheduled. Merely
cordoning without workload eviction would not empty the old instance manager because Task 52
shows it is hosting active engines for attached volumes.

If Semaphore itself is interrupted after the cordon and before the Ansible cleanup path, use the
independent break-glass route and run:

```bash
kubectl uncordon k8s-worker02
```

Do not activate or execute this canary without explicit operator approval.

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

Planned stages after the live drain canary proves ordinary eviction behavior:

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

The single control-plane node has no HA fallback. Before host/Kubernetes mutation re-confirm etcd
recovery, Longhorn backups/volume health, Vault/Semaphore recovery and the independent admin
break-glass route.
