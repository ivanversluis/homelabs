# 2026-09 platform catch-up upgrade retrospective

Status: **coordinated platform baseline restored**.

In September 2026 the homelab completed its first full coordinated Arch Linux + Kubernetes
maintenance cycle after roughly one year of accumulated platform drift. This was more than a
version bump: it converted a fragile manual upgrade problem into an evidence-driven, recoverable
maintenance process that can be repeated.

## Achievement

The cluster converged to:

| Component | Result |
|---|---|
| Kubernetes API/control plane | v1.36.4 |
| kubeadm/kubelet/kubectl on all four nodes | 1.36.4-1 |
| master01 kernel | 7.2.6-arch2-1 |
| worker01 kernel | 7.2.6-arch2-1 |
| worker02 kernel | 7.2.6-arch2-1 |
| worker03 kernel | 7.2.6-arch2-1 |
| master01 containerd | 2.4.0 |
| worker01 containerd | 2.3.5 |
| worker02 containerd | 2.3.5 |
| worker03 containerd | 2.4.0 |
| Calico | v3.32.1 |
| Longhorn manager | v1.12.1 |

The final per-node completion gate proved all four hosts had the target Kubernetes packages and
active services. The remaining final-gate blocker was not an upgrade failure: the KubeVirt CDI
importer for the Debian test VM was still provisioning a DataVolume on worker03. The same expected
transient workload also caused the subsequent maintenance-readiness report to remain BLOCKED until
the import converges.

## Starting condition

The catch-up work began with meaningful skew and technical debt:

- control-plane Kubernetes components were behind the current Arch package candidate;
- workers were on older 1.35.x kubelet packages;
- kernels/containerd were behind the rolling Arch baseline;
- system Python had previously been broken by a partial-upgrade class of incident, so automation
  depended on a private standalone interpreter;
- kubeadm ClusterConfiguration contained a malformed duplicate mapping;
- Longhorn drain behavior was not yet proven with current instance-manager/PDB behavior;
- the single control-plane host had no HA fallback.

That combination made a blind `pacman -Syu` across the cluster unacceptable.

## What worked

### Fail-closed gates

Every mutating step validated the current cluster state before changing anything. Longhorn, Calico,
Flux, node readiness, repository candidates and backups were checked repeatedly.

### Control-plane-first Kubernetes ordering

The API/control-plane was upgraded before kubelets moved to the new minor. Host package maintenance
was kept separate from `kubeadm upgrade apply`, preventing Arch's rolling package model from
breaking Kubernetes version ordering.

### Fresh recovery checkpoints

A fresh etcd snapshot and Longhorn SystemBackup were required before the control-plane mutation and
again before the control-plane host reboot. The two-hour freshness gate prevented stale recovery
evidence from being reused.

### One-node-at-a-time host maintenance

Workers were upgraded sequentially with a real canary first. No concurrent `pacman -Syu`, no
forced drain, and no PDB bypass was used.

### Longhorn protection remained intact

Drains used normal Kubernetes eviction semantics. Longhorn volumes were allowed to degrade
temporarily while replicas moved, but host package mutation did not start until all volumes returned
to healthy.

## Lessons learned

### 1. A five-minute Longhorn recovery timeout was too short

Worker01 and especially worker03 demonstrated that normal replica reconstruction can exceed five
minutes after an instance-manager eviction. The first automation repeatedly failed safely before
package mutation.

Change made:

- storage stabilization timeout: 300 seconds -> 1200 seconds;
- keep the node cordoned while waiting;
- never weaken the Longhorn PDB or node-drain policy just to make maintenance faster.

### 2. Credential lifetime must include recovery time

The original 30-minute Vault SSH certificate was too tight once Longhorn recovery, package
synchronization, reboot and post-checks were combined.

Change made:

- playbooks 66-70 now request a 60-minute certificate;
- shorter/read-only control-tower work keeps the 30-minute default.

### 3. Controller-side reboot waiting must not depend on the managed node's Python

The first reboot workflow used an Ansible connection wait path that depended on remote Python state.
It was replaced by a controller-side TCP/22 wait plus boot-ID verification.

### 4. Delegated localhost tasks must not inherit remote sudo

A post-reboot wait failed inside the Semaphore container because a delegated localhost task inherited
the cluster-wide become setting. `host_vars/localhost.yml` now makes the local execution path
explicitly unprivileged.

### 5. Pacman 7 DownloadUser changes affect isolated repository probes

The isolated pacman database directories originally used permissions that prevented the download
user from accessing them. The probe path was corrected without weakening host package safety.

### 6. Shell embedded in Ansible must be kept simple

Two failures were automation defects rather than infrastructure failures:

- an inline comment/apostrophe triggered raw-shell parsing trouble;
- an inline Jinja-generated `test` caused `test: too many arguments` after worker03 was already
  successfully upgraded and uncordoned.

The final health condition was rewritten as normal POSIX shell.

### 7. Modern Python must not be tested with removed stdlib modules

After the full Arch upgrade, maintenance-readiness still reported system Python as broken because
its functional probe imported `spwd`, a deprecated/removed module on modern Python.

Change made:

- system and fallback Python probes use stable modules only;
- the standalone interpreter remains a fallback, not a permanent dependency.

### 8. Worker03 is not a normal worker

Worker03 hosts the KVM/local-path VM capability. CDI importers and VM storage are intentionally
pinned there. Draining worker03 therefore has different consequences from worker01/02 and can pause
or restart VM image provisioning.

The automation should continue treating worker03 as a worker for host maintenance, but operators
must inspect KubeVirt/CDI state before interpreting a post-maintenance Pending importer as a cluster
failure.

### 9. Final health gates should remain strict

Playbook 71 and playbook 50 both blocked on `vms/importer-debian-bookworm-dv`. This was useful:
the infrastructure upgrade had succeeded, but the entire workload plane had not yet converged.

Decision:

- do not hide this class of workload automatically;
- inspect it, wait for normal CDI completion, then rerun the final gates;
- use an explicit accepted exception only after conscious operator review.

### 10. Vault is a recovery dependency

The control-plane reboot restarted Vault. The current standalone/file-backed Shamir design comes
back sealed, so new Semaphore runs cannot obtain ephemeral SSH certificates until Vault is manually
unsealed.

Tracked in issue #256. Until resolved, the manual unseal path is part of the control-plane reboot
runbook.

### 11. External tunnel availability depended on the control-plane node

The Cloudflare Tunnel had one replica with required affinity to the single control-plane node.
Rebooting that node removed the only connector and temporarily removed external access.

Tracked in issue #257. No real public FQDNs are recorded in the issue or this document.

### 12. Application image tags matter during drains

A normal eviction can recreate an application on another node. If the workload uses `latest` plus
`imagePullPolicy: Always`, maintenance can accidentally become an application upgrade. The Homebox
incident during the drain canary demonstrated this.

Operational workloads should use explicit tested image versions, preferably immutable digests where
practical.

## Playbook disposition after the catch-up cycle

| Playbook | Disposition |
|---|---|
| 50 maintenance readiness | Keep; mandatory before and after maintenance |
| 60 Wave 3 preflight | Keep; reusable read-only platform preflight |
| 61 execution gate | Keep as optional diagnostic |
| 62 kubeadm config repair | Historical one-off; do not run routinely |
| 63 Longhorn drain readiness | Troubleshooting only |
| 64 Longhorn engine audit | Troubleshooting only |
| 65 live drain canary | Optional only after meaningful drain/storage changes |
| 66 recovery checkpoint | Keep; mandatory before control-plane mutation/reboot |
| 67 control-plane Kubernetes upgrade | Keep; target now centrally configured |
| 68 worker upgrade canary | Keep; canary now centrally configured |
| 69 remaining worker upgrade | Keep; generic one-worker execution |
| 70 control-plane host upgrade | Keep; reusable |
| 71 completion gate | Keep; mandatory final platform/workload validation |

The filenames remain for compatibility with existing Semaphore templates. The operational process is
now documented in `recurring-platform-upgrade.md`.

## Result

The important result is not only that the cluster reached Kubernetes v1.36.4 and a current Arch
baseline. The homelab now has a tested maintenance mechanism with:

- explicit target review;
- recovery checkpoints;
- control-plane-first Kubernetes ordering;
- one-node-at-a-time Arch maintenance;
- Longhorn-aware drain behavior;
- short-lived Vault SSH credentials;
- independent break-glass access;
- post-reboot and final cluster health gates;
- documented failure and recovery behavior.

The next platform maintenance window should be a routine lifecycle operation rather than another
one-year catch-up project.
