# maintenance_readiness

Wave 0.5 read-only maintenance-readiness assessment. Determines whether the cluster is
healthy enough to safely start Wave 1 (Longhorn) and beyond, without changing anything.

Reused rather than duplicated:
- Vault/SSH certificate trust and the `ansible`/sudo route — proven by `control_tower_validation`
  (included in the same play, before this role) and by the fact this playbook is running at
  all through `scripts/lifecycle/semaphore-control-tower-run.sh`.
- Cluster-API access — uses the control-plane node's own root-readable
  `/etc/kubernetes/admin.conf` via the existing SSH/sudo trust, instead of granting the
  Semaphore ServiceAccount new Kubernetes RBAC.

## What it checks

- **Host/Arch** (every node): root filesystem capacity/inode usage, kernel-vs-installed-modules
  reboot indicator, Arch package + live kubelet/kubeadm/kubectl binary versions, system vs.
  standalone control-tower Python state.
- **Kubernetes** (control-plane node only, via its admin kubeconfig): node Ready/conditions/
  unschedulable state, per-node kubelet version skew, pods not Running/Ready, restart counts/
  CrashLoopBackOff/ImagePull failures, PodDisruptionBudgets that would block `kubectl drain`,
  unmanaged ("bare") pods that would block drain without `--force`, single-control-plane risk.
- **Calico**: `calico-node`/`csi-node-driver` DaemonSet health, controller/Typha Deployment
  health, Tigera operator component status, installed version/CNI config.
- **Longhorn**: manager/CSI-plugin DaemonSet health, driver-deployer/UI Deployment health,
  volume robustness (attached volumes only — detached volumes report `robustness=unknown` by
  design and are not a problem), single-replica (no redundancy) volumes, node schedulable/disk
  health, installed version, and the `node-drain-policy` setting.
- **Flux**: Kustomization/HelmRelease Ready status, with suspended resources reported
  separately from actual failures.

## Output

Every check appends a finding (`id`, `component`, `severity`, `observed`, `evidence`,
`impact`, `remediation`, `blocks_next_wave`) to that host's `maintenance_findings` list.
`tasks/report.yml` (run once, on `localhost`, from the playbook's second play) aggregates
every node's findings, computes the overall verdict, and renders
`{{ maintenance_readiness_report_dir }}/{{ maintenance_readiness_run_id }}.md`:

- **READY** — no blocker or exception findings.
- **READY WITH ACCEPTED EXCEPTIONS** — only exception-severity findings, or blocker findings
  whose IDs are explicitly listed in `maintenance_readiness_accepted_exceptions`.
- **BLOCKED** — at least one blocker finding whose ID is not in
  `maintenance_readiness_accepted_exceptions`. The playbook run itself fails in this case.

Severity is deliberately non-fatal per-check (`failed_when` is never used for a health
condition) so a single unhealthy component never stops the rest of the assessment from
running — only the final verdict task can fail the run, and only when BLOCKED.
