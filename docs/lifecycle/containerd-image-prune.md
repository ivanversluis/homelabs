# Weekly containerd image cleanup

## Purpose

This job prevents unused CRI images from silently filling the Kubernetes nodes' root filesystems
and making Longhorn disks unschedulable. It uses the supported CRI cleanup operation only:

```bash
crictl --runtime-endpoint unix:///run/containerd/containerd.sock rmi --prune
```

It never removes files directly from `/var/lib/containerd`, containerd snapshots, or Longhorn.
Images used by containers remain available.

## Execution path

```text
Semaphore schedule
  -> Bash task template
  -> scripts/lifecycle/semaphore-control-tower-run.sh
  -> Vault Kubernetes auth
  -> ephemeral SSH certificate for principal ansible
  -> automation/ansible/playbooks/96-containerd-image-prune.yml
  -> one Kubernetes node at a time
```

The playbook fails immediately if `crictl` is missing, containerd is inactive, or the CRI endpoint
does not answer. A failure stops the remaining nodes. No drain or reboot is performed.

For every node, the Semaphore task output records:

- `df -hP /` and exact root-used bytes before and after;
- `du -sh /var/lib/containerd` and exact containerd bytes before and after;
- CRI image count before and after;
- running container count before and after;
- the `crictl rmi --prune` output;
- reclaimed root and containerd capacity in MiB.

## Schedule

The managed default is Sunday at 04:00 Europe/Amsterdam:

```text
0 4 * * 0
```

`infra/semaphoreui/semaphoreui-helmrelease.yaml` sets
`SEMAPHORE_SCHEDULE_TIMEZONE=Europe/Amsterdam`. The cadence is stored in Semaphore orchestration,
not in the playbook.

## Provision or reconcile the Semaphore objects

After the branch containing the playbook is available to Semaphore, run from a workstation with
the homelab `kubectl` context:

```bash
./scripts/lifecycle/configure-semaphore-image-prune.sh
```

The script:

1. opens a temporary localhost port-forward to the Semaphore service;
2. reads the existing admin username/password from `Secret/semaphoreui-secrets` without printing
   them, then authenticates to the API;
3. discovers the Homelab project and `homelabs` repository;
4. creates or updates the Bash task template;
5. creates or updates and activates the weekly schedule;
6. removes its cookie file and closes the port-forward.

It is safe to run repeatedly. Existing objects with the managed names are updated rather than
duplicated. An API token and external URL can be used instead:

```bash
SEMAPHORE_URL=https://demo-semaphoreui.example.net \
SEMAPHORE_API_TOKEN='<token>' \
./scripts/lifecycle/configure-semaphore-image-prune.sh
```

Useful overrides include `SEMAPHORE_PROJECT_NAME`, `SEMAPHORE_REPOSITORY_NAME`,
`SEMAPHORE_CRON`, and `SEMAPHORE_GIT_BRANCH`.

## Manual run

In Semaphore, open **Homelab Ops - Weekly containerd image prune** and select **Run**. The managed
template passes these arguments to the existing control-tower runner:

```text
playbook=playbooks/96-containerd-image-prune.yml
limit=k8s_homelab
```

Review the before/after block for every node and confirm the task completes for all four nodes. A
second manual run should report no deleted images and near-zero reclaimed capacity, proving the
operation is idempotent.

## Failure handling

- A node failure is visible as a failed Semaphore task and stops the sequence.
- Do not delete containerd or Longhorn files manually.
- Fix the reported `crictl`, CRI socket, containerd service, Vault, or SSH issue and rerun the task.
- The independent `admin` break-glass route is unchanged.

