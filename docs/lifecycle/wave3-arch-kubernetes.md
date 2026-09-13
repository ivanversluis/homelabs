# Wave 3: coordinated Arch Linux + Kubernetes

Status: **LIVE PREFLIGHT COMPLETE — KUBEADM CONFIG REPAIRED — LONGHORN ENGINE AUDIT COMPLETE — WORKER DRAIN CANARY PROVEN**.

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
- each worker initially ran two AIO instance managers: one `v1.12.1` and one `v1.11.0-hotfix-1`.

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
- active engines were still hosted by old v1.11.0-hotfix-1 instance managers for attached volumes.

Therefore Wave 1 engine migration itself was complete. The remaining v1.11 instance managers were
runtime leftovers rather than old volume/engine/replica image references.

## Live worker drain canary — Semaphore tasks 53/54

The one-worker canary targeted only `k8s-worker02` and used normal Kubernetes eviction/PDB
semantics. No `--disable-eviction`, `--force`, manual Longhorn pod deletion, weaker drain policy,
host package change, or Kubernetes version change was used.

Task 53 proved the first part of the behavior:

- worker02 was cordoned successfully;
- normal application workloads were evicted and rescheduled;
- the old `v1.11.0-hotfix-1` instance manager on worker02 disappeared naturally after its active
  engine workloads moved;
- the drain remained blocked by the current `v1.12.1` instance-manager PDB and timed out;
- the Ansible `always` cleanup uncordoned worker02 and verified it was Ready and schedulable.

Task 54 then reran the same approved canary after the application workloads had already moved.
The pre-canary workload list on worker02 contained only DaemonSet-managed pods plus the current
v1.12.1 instance manager. The normal drain then evicted that instance manager successfully and
reported:

```text
pod/instance-manager-5f7710522e9b0413393cb882b256db0b evicted
node/k8s-worker02 drained
```

Longhorn volumes temporarily transitioned away from healthy while storage reconciled, then all
volumes returned to `healthy` within the configured five-minute stabilization window. The current
v1.12.1 instance manager was recreated on worker02 while the node was still cordoned, and the
canary finally uncordoned worker02 and verified `Ready=True` and `unschedulable=false`.

Together Tasks 53 and 54 prove the required maintenance behavior, but also show that a production
node-maintenance playbook must model drain as a staged/retry operation rather than assuming that a
fully loaded Longhorn worker always drains in one pass. The safe pattern is:

1. cordon the worker once;
2. run normal drain/evictions;
3. if only Longhorn instance-manager PDBs remain, keep the node cordoned and wait for workload and
   volume reconciliation instead of weakening PDB protection;
4. retry the normal drain after Longhorn has reconciled;
5. require all volumes healthy before host mutation or reboot;
6. keep the node cordoned throughout host maintenance;
7. uncordon only after the upgraded node and full cluster health checks pass.

The canary activation flag has been reset to `false` after the successful test so it cannot be
rerun accidentally.

## Target-selection rule

Kubernetes `v1.36.4` was the Arch-repository candidate seen by the earlier preflight and remains
the intended minor target only after a fresh package/version check immediately before mutation.
The current kubeadm binary is still 1.35.x, so its current plan resolves only the 1.35 patch line.
The supported kubeadm minor-upgrade sequence requires upgrading kubeadm first, re-running
`kubeadm upgrade plan`, then applying the control-plane upgrade before kubelets move to the new
minor.

Do not jump to Kubernetes 1.37 without a new compatibility and target review.

## Arch/Kubernetes sequencing model

Arch is rolling release and does not support arbitrary partial system upgrades. Kubernetes,
however, requires kubeadm/control-plane-first ordering for a minor upgrade and kubelets must not
be advanced ahead of the API server. Wave 3 must therefore keep these concerns explicit rather
than running one blind `pacman -Syu` loop.

Before any host or Kubernetes mutation, take a fresh etcd snapshot and re-confirm current Longhorn
backup/volume health, control-tower recovery, and the independent admin break-glass path.

The actual mutation playbooks must now be built around the proven staged drain behavior and a
freshly validated Kubernetes/Arch target. Do not reuse the earlier conceptual package-ordering
sequence blindly; re-evaluate how to avoid advancing kubelet ahead of kube-apiserver while also
respecting Arch's no-partial-upgrade rule.

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
