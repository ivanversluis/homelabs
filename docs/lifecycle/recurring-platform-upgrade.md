# Recurring platform upgrade runbook

This is the repeatable maintenance path for the Arch Linux + kubeadm Kubernetes homelab after the
2026-09 catch-up cycle. The existing playbook numbers and `wave3_*` role names are retained for
Semaphore/template compatibility, but the target versions are now configured centrally and the
same workflow is intended to be reused for future maintenance windows.

## Central lifecycle target

Before every maintenance window, review and update only the lifecycle baseline in:

`automation/ansible/inventories/homelab/group_vars/all.yml`

```yaml
lifecycle_kubernetes_current_version: "v1.36.4"
lifecycle_kubernetes_target_version: "v1.36.4"
lifecycle_kubernetes_target_minor: "1.36"
lifecycle_kubernetes_target_package_prefix: "1.36.4-"
lifecycle_worker_canary: "k8s-worker02"
lifecycle_expected_calico_version: "v3.32.1"
lifecycle_expected_longhorn_manager_image: "docker.io/longhornio/longhorn-manager:v1.12.1"
```

For a future Kubernetes target, change these values in a reviewed PR only after checking:

- the live Arch repository candidates for kubeadm/kubelet/kubectl;
- kubeadm-supported source -> target ordering;
- the current Calico and Longhorn compatibility/support state;
- Longhorn volume/backup health;
- the independent `admin` break-glass route;
- Vault recovery/unseal readiness.

Do not silently accept a newer Arch Kubernetes package. The mutating node-upgrade role probes the
live repository in an isolated pacman database and fails closed unless the candidate matches the
reviewed package prefix.

## Choose the maintenance mode

Use the same fail-closed node-maintenance roles for both modes, but do not perform an unnecessary
Kubernetes control-plane apply when the reviewed Kubernetes target is unchanged.

**Mode A — Arch + Kubernetes target change**

Use when `lifecycle_kubernetes_target_version` differs from
`lifecycle_kubernetes_current_version`:

```text
50 -> 60 -> 66 -> 67 -> 68 -> 69 (one worker at a time) -> 66 -> 70 -> 71 -> 50
```

The first 66/67 pair is required because the API/control plane must reach the reviewed Kubernetes
target before any kubelet package is moved to that target.

**Mode B — Arch maintenance with Kubernetes target unchanged**

Use when current and target Kubernetes versions are identical and the live repository still offers
the reviewed Kubernetes package prefix:

```text
50 -> 60 -> 68 -> 69 (one worker at a time) -> 66 -> 70 -> 71 -> 50
```

The first 66/67 pair can be skipped. The fresh checkpoint immediately before playbook 70 remains
mandatory because the single control-plane host will reboot.

If the isolated repository probe shows that Arch now offers a different Kubernetes package version,
stop and review a new lifecycle target. Do not let an Arch-only window implicitly become a Kubernetes
upgrade.

## Normal recurring sequence

### 1. Baseline readiness

```text
playbook=playbooks/50-maintenance-readiness.yml
limit=k8s_homelab
```

This gate is intentionally strict. A known workload that is temporarily provisioning, such as a CDI
VM-image importer, may block the verdict even while the platform is healthy. Investigate the object,
wait for normal convergence, and rerun the gate. Do not add a permanent exception merely to make the
maintenance task green.

### 2. Read-only platform preflight

```text
playbook=playbooks/60-wave3-preflight.yml
limit=k8s_homelab
```

This checks host/package state, pacman consistency, Kubernetes versions, kubeadm planning, Calico,
Longhorn, Flux and system-Python state without mutation.

### 3. Optional diagnostics only when needed

The following playbooks are retained because they were valuable during the 2026-09 recovery, but
they are not part of every monthly cycle:

| Playbook | Use |
|---|---|
| 61 | Optional kubeadm/drain diagnostic when configuration or drain behavior changed |
| 62 | Historical one-off duplicate kubeadm ConfigMap repair |
| 63 | Longhorn drain troubleshooting |
| 64 | Longhorn engine/instance-manager troubleshooting |
| 65 | Optional live drain experiment after major storage/drain behavior changes |

Routine maintenance should not run 62-65 by habit.

### 4. Fresh recovery checkpoint for a Kubernetes target change

When `lifecycle_kubernetes_target_version` differs from
`lifecycle_kubernetes_current_version`, create the checkpoint before playbook 67:

```text
playbook=playbooks/66-wave3-recovery-checkpoint.yml
limit=k8s-master01
```

Require `WAVE 3 RECOVERY CHECKPOINT: READY`. The checkpoint contains a checksum-verified etcd
snapshot plus a Ready Longhorn SystemBackup with volume backups.

If current and target Kubernetes versions are identical, skip this checkpoint here and continue
with the worker canary. A separate fresh checkpoint is still mandatory before playbook 70.

### 5. Kubernetes control-plane target (only when target changes)

```text
playbook=playbooks/67-wave3-control-plane-upgrade.yml
limit=k8s-master01
```

The target kubeadm binary is downloaded independently and checksum-verified before
`kubeadm upgrade apply`. If the API server is already at the configured target, the apply step is
skipped while the validation path still runs.

Kubernetes minor upgrades remain control-plane-first. Never move kubelets to a newer minor before
the API server.

### 6. Worker canary

```text
playbook=playbooks/68-wave3-worker-upgrade-canary.yml
limit=<configured lifecycle_worker_canary>
```

The configured canary is currently `k8s-worker02`. The playbook itself verifies that the supplied
limit matches the central canary setting.

### 7. Remaining workers, one at a time

```text
playbook=playbooks/69-wave3-worker-upgrade.yml
limit=<one non-canary worker>
```

Run a separate Semaphore task for every remaining worker. Never pass the entire worker group.

The safe worker sequence is:

```text
cordon
-> normal drain with PDBs
-> wait for Longhorn replica stabilization
-> full pacman -Syu
-> verify exact Kubernetes packages
-> kubeadm upgrade node
-> reboot
-> wait SSH
-> verify node/Calico/Longhorn
-> uncordon
-> verify Flux and final node health
```

Longhorn replica rebuilding took longer than five minutes during the 2026-09 cycle, so the role
allows up to 20 minutes before failing the pre-mutation storage-health gate. PDBs are never bypassed.

### 8. Refresh the checkpoint before control-plane host maintenance

Always run playbook 66 again immediately before playbook 70. The control-plane host upgrade rejects
a checkpoint older than two hours.

### 9. Control-plane host Arch/kubelet maintenance

```text
playbook=playbooks/70-wave3-control-plane-host-upgrade.yml
limit=k8s-master01
```

All workers must already be Ready at the reviewed target. This step performs the full Arch
synchronization on the single control-plane host and reboots it.

Current operational dependencies exposed by the 2026-09 cycle:

- Vault starts sealed after its pod restarts. Until issue #256 is resolved, manually unseal Vault
  through the independent recovery path before launching the next Vault-dependent Semaphore task.
- The Cloudflare Tunnel currently has a single connector pinned to the control-plane node. Until
  issue #257 is resolved, external access can disappear during the control-plane reboot. The
  maintenance job itself continues server-side.

Do not put public FQDNs, credentials, tunnel IDs, tokens, certificates or unseal material into
issues, logs committed to Git, or examples.

### 10. Final completion gate

```text
playbook=playbooks/71-wave3-completion-gate.yml
limit=k8s_homelab
```

This validates package/service state on every node, then verifies cluster-wide Kubernetes,
Longhorn, Calico, Flux, workload and OIDC health.

If it blocks on an expected transient workload, inspect that workload and wait for convergence.
Keep the final gate strict rather than making transient application failures invisible.

### 11. Final maintenance-readiness report

```text
playbook=playbooks/50-maintenance-readiness.yml
limit=k8s_homelab
```

A clean recurring cycle ends only when the final readiness report has no unaccepted blockers.

### 12. Close the lifecycle baseline

After a successful cycle, update the central baseline so the next window starts from the state that
was actually achieved:

```yaml
lifecycle_kubernetes_current_version: "<the completed target>"
lifecycle_kubernetes_target_version: "<the completed target>"
```

Commit that closure together with the maintenance record. Do not leave `current_version` pointing
at the pre-upgrade source version.

## Credential timing

The Semaphore control-tower runner uses:

- 60-minute Vault SSH certificates for playbooks 66-70;
- the normal 30-minute certificate for read-only/shorter jobs.

The longer TTL is needed because a Longhorn SystemBackup or post-drain replica rebuild can consume a
large part of a 30-minute certificate lifetime.

## Arch Linux rules

- Use a full `pacman -Syu`; never use `pacman -Sy <package>`.
- Upgrade one node at a time.
- Probe repository candidates in an isolated database before mutation.
- Reboot after host package synchronization.
- Treat Kubernetes packages as part of the coordinated target; do not let a rolling Arch repository
  silently decide the Kubernetes version.

## Failure behavior

A failed worker run after cordon intentionally leaves evidence in:

```text
/var/lib/homelab-maintenance/wave3-node-upgrade.env
```

Do not reflexively uncordon or rerun. Determine whether failure occurred before or after package
mutation, verify Longhorn/Calico/node state, and then choose recovery or resume.

The role names and marker paths still contain `wave3` for compatibility with existing Semaphore
templates and historical evidence. They are now the recurring coordinated-platform-maintenance
implementation.
