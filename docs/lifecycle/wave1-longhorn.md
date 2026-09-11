# Wave 1: Longhorn v1.12.1

## Status

**Preparation only. No Longhorn upgrade is active.** Wave 0.5 completed with an
authoritative `READY WITH ACCEPTED EXCEPTIONS` verdict and no blockers. The next gate is the
read-only Semaphore playbook `playbooks/55-longhorn-upgrade-preparation.yml`.

The existing Synology copy of the Wave -1 backup remains verified disaster-recovery
evidence. Before execution, Wave 1 additionally requires a fresh Longhorn `SystemBackup` in
state `Ready`, created with `volumeBackupPolicy: always`, so Longhorn configuration and every
volume have current native backup coverage.

## Source and target

- Current upstream base: Longhorn v1.11.0 manifest.
- Current live override: `longhorn-manager` and `longhorn-instance-manager`
  `v1.11.0-hotfix-1`.
- Hotfix rationale: v1.11.0 manager had a Kubernetes-node-validator/CNI startup deadlock;
  v1.11.0 instance-manager had proxy connection leaks and increasing memory usage. The repo
  history contains no local rationale, but its overrides match the v1.11.0 upstream hotfix
  notice.
- Target: Longhorn v1.12.1, upstream commit
  `f349c091c50700cb6cb8a4df8aaa29ea214bdd48`.
- Vendored manifest SHA-256:
  `41648963af867ac1d0c85755fb53cf61cacd57c9bb22e1942e3fb0439eeb04fd`.

Longhorn v1.12.1 supports upgrading from v1.11.x. Kubernetes 1.35 is in its tested version
set. Manager/system resources are upgraded first. Healthy V1 volumes can then receive a live
engine upgrade; V2 volumes cannot and must be detached with their replicas stopped before
the manager upgrade.

The v1.12.1 manifest also introduces ingress NetworkPolicies for Longhorn's internal
components. This cluster has a policy-capable Calico CNI. Post-manager validation must
therefore include Longhorn webhook/manager/instance-manager communication and the existing
Kong/Cloudflare UI paths; a healthy-looking rollout alone is not sufficient.

## Preparation gate

Run in Semaphore:

```text
playbook=playbooks/55-longhorn-upgrade-preparation.yml
limit=k8s_homelab
```

The playbook performs only Kubernetes GET operations and checks:

- deployed manager and driver-deployer images and supported v1.11.x source path;
- volume robustness/state and failed replica state;
- V1/V2 volume, replica, and engine state;
- failed BackingImages and BackingImageDataSources;
- backup-target availability, ready system backups, completed volume backups, backup age,
  and `volumeBackupPolicy`;
- every current StorageClass, including default status, reclaim policy, binding mode, data
  engine, and replica count.

`READY FOR APPROVAL` means the live state is eligible for review. It does not authorize an
upgrade.

## Exact GitOps activation diff (not applied)

After a successful preparation gate and explicit operator approval, make only this active
configuration change in `services/storage/longhorn/k8s/kustomization.yaml`:

```diff
 resources:
-  - https://raw.githubusercontent.com/longhorn/longhorn/v1.11.0/deploy/longhorn.yaml
+  - vendor/longhorn-v1.12.1.yaml
   - config/longhorn-worker-sc.yaml
 
 patchesStrategicMerge:
   - patches/default-setting.yaml
   - patches/storageclass.yaml
-  - patches/manager-hotfix.yaml
-  - patches/driver-deployer-hotfix.yaml
+  - patches/manager-v1.12.1.yaml
```

The two v1.11.0 hotfix patches must then be deleted. The replacement manager patch preserves
only the worker scheduling constraint; v1.12.1's upstream manifest supplies all release
images and command arguments. No StorageClass parameter is changed by this diff.

## Execution and stop points

1. Confirm the preparation playbook returns `READY FOR APPROVAL` and review its StorageClass
   inventory.
2. Confirm the fresh native Longhorn system/volume backup and the existing Synology archive.
3. Obtain explicit approval for the exact GitOps diff above.
4. Commit the active diff and allow Flux to upgrade manager/system resources.
5. Stop and validate all Longhorn workloads, volumes, replicas, BackingImages, and workload
   mounts. Do not begin a node-by-node Arch-style procedure.
6. Upgrade healthy V1 volume engines only after the manager/system upgrade is healthy.
7. Re-run Wave 0.5 and the Wave 1 validation before Wave 2 Calico.

There is no supported downgrade after a successful v1.12.1 upgrade. Any blocker or
unexpected reconciliation behavior stops Wave 1 for operator review.
