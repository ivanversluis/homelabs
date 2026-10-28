# Diagnose Kubernetes node disk pressure with Semaphore

## Existing capabilities and gap

`automation/ansible/playbooks/95-disk-report.yml` (used during the Kubernetes
upgrade preparation) displays `df`, inodes, `lsblk`, and the **total** sizes
of six fixed paths such as `/var/lib/containerd` and `/var/lib/longhorn`.
It does **not** list all first-level directories or drill into the largest ones.
`96-containerd-image-prune.yml` removes unused CRI images and must not be
treated as a diagnostic.

The new `97-disk-path-investigation.yml` is strictly **read-only**: no image
pruning, log cleanup, deletions, restarts, draining, or PVC modifications.

## What the report contains

Each selected node is scanned sequentially, through the existing
Semaphore -> Vault Kubernetes auth -> short-lived SSH certificate -> `ansible`
account -> sudo route. It does not require a direct node terminal or a working
remote Python installation.

1. `df -hPT`, `df -iP`, and `findmnt` for the root filesystem.
2. A **complete first-level directory list** below `/`, sorted largest first.
   The report shows the filesystem **total** separately to avoid double-counting.
3. A drill-down into the **largest immediate subdirectory** at each depth,
   default five levels from `/`. The next level lists the 15 largest child
   directories. Example path: `/ -> /var -> /var/lib -> /var/lib/containerd`.
4. A separate two-level breakdown of `/var/lib/longhorn` even when this is
   not the root's largest branch. Its own filesystem is shown, since Longhorn
   could use a separately mounted disk.
5. Allocated journal usage (`journalctl --disk-usage`) and an explicit
   incomplete-scan warning if `du` times out or errors.

GNU `du -x` stays within each filesystem and does not traverse nested
PVC mounts. It runs at `nice -n 19`, `ionice -c3` when available, and
limits each directory scan to 120 seconds. The report is printed even when
some scans are incomplete; the Ansible task then fails rather than implying
the results are comprehensive. No diagnostic report is written onto a
potentially full node disk. Scans can still generate disk I/O.

**Important:** `df` and `du` can differ due to filesystem reservations,
deleted-but-open files, and filesystem metadata. A directory breakdown alone
cannot prove why Longhorn declared a disk `Schedulable=false`; compare it
with the Longhorn conditions in `docs/longhorn-scheduling-alerting.md`.

## Configure a one-click Semaphore template

After merging this PR, from your administration workstation, once:

```bash
bash scripts/lifecycle/configure-semaphore-disk-investigation.sh
```

This idempotently provisions a **manual-only** Bash task named
**Homelab Ops - Disk path investigation (k8s-worker03)**. It uses the
existing control-tower runner:

```text
playbook=playbooks/97-disk-path-investigation.yml
limit=k8s-worker03
```

Then in Semaphore select **Homelab Ops - Disk path investigation
(k8s-worker03)** → **Run**. Read the node breakdown in task output,
including the deepest investigated paths. **No shell login is required.**

To add a separate named task for another host:

```bash
SEMAPHORE_LIMIT=k8s-worker01 bash scripts/lifecycle/configure-semaphore-disk-investigation.sh
SEMAPHORE_LIMIT=k8s-worker02 bash scripts/lifecycle/configure-semaphore-disk-investigation.sh
```

Only the four known node names are accepted. Run one host at a time to keep the Vault SSH certificate lifetime and disk-scan load predictable.
The template does not allow runtime changes to CLI arguments or Git branch.
Creating or updating a Semaphore task requires cluster/API access from the
administration workstation; execution afterwards uses the Semaphore UI.

The template is deliberately not scheduled: root `du` scans can be expensive
and are better run on demand after capacity alerts.

## Interpreting outcomes

- Large `/var/lib/containerd`: inspect images/snapshots and consider the
  existing approved weekly `96-containerd-image-prune.yml`. Never `rm -rf`
  containerd snapshot directories.
- Large `/var/lib/longhorn`: check replica sizes and snapshots in Longhorn,
  replica rebuilds, scheduling conditions and Longhorn's own disk telemetry.
  Never manually delete replica directories.
- Large `/var/log/journal` or `/var/log`: inspect journald allocation and
  log rotation before deciding on retention changes.
- Large `/var/lib/kubelet`: check separately for pod/container mounts and
  supported CSI volume details. This scan intentionally does not descend
  into other filesystem mounts.
- High `df` without corresponding `du` directories: investigate
  deleted-but-open files, reserved blocks or other filesystem metadata,
  rather than pruning blindly.

The playbook **does not automatically remove files**. Review the output and
only then select a separate, supported cleanup action.

## Validation and limitations

```bash
python3 scripts/lifecycle/tests/disk-path-investigation.py
bash scripts/lifecycle/tests/configure-semaphore-disk-investigation.sh
bash -n scripts/lifecycle/configure-semaphore-disk-investigation.sh
```

CI also checks every Ansible playbook's syntax. Synthetic filesystem tests
prove drill-down selection without touching the real host root; they cannot
replace a live Semaphore run or Longhorn disk-condition evidence.
