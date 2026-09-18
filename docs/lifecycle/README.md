# Homelab lifecycle documentation

This directory is the operational record and runbook set for maintaining the homelab platform.

## Current platform baseline

The 2026-09 catch-up maintenance completed the first full coordinated Arch Linux + Kubernetes
lifecycle cycle after approximately one year of accumulated host/platform drift.

Current reviewed baseline:

| Component | Baseline |
|---|---|
| Kubernetes API/control plane | v1.36.4 |
| kubeadm/kubelet/kubectl | 1.36.4-1 on all four nodes |
| Calico | v3.32.1 |
| Longhorn manager | v1.12.1 |
| Host OS | full Arch system upgrade completed on every node |

The maintenance process itself is now reusable rather than being a one-off recovery exercise.

## Start here

- [Recurring platform upgrade](./recurring-platform-upgrade.md) — normal future Arch + Kubernetes
  maintenance sequence.
- [2026-09 platform upgrade retrospective](./2026-09-platform-upgrade-retrospective.md) — milestone,
  evidence and lessons learned from the catch-up cycle.
- [Maintenance plan](./maintenance-plan.md) — overall lifecycle model and wave status.
- [Wave 3 Arch + Kubernetes](./wave3-arch-kubernetes.md) — historical engineering record.
- [Wave 3 node-upgrade execution](./wave3-node-upgrade-execution.md) — historical first execution
  runbook retained for traceability.

## Recurring operational path

The coordinated path depends on whether Kubernetes itself changes.

Kubernetes target change:

```text
50 -> 60 -> 66 -> 67 -> 68 -> 69 (one worker at a time) -> 66 -> 70 -> 71 -> 50
```

Arch-only maintenance with the Kubernetes target unchanged:

```text
50 -> 60 -> 68 -> 69 (one worker at a time) -> 66 -> 70 -> 71 -> 50
```

The checkpoint immediately before the single control-plane host reboot is always mandatory.

Playbooks 61-65 remain available as diagnostics/historical repair tools but are not routine steps.
The existing `wave3_*` filenames and role names are retained for Semaphore compatibility.

## Open resilience follow-ups

- Issue #256: Vault seals after restart and blocks new Vault-dependent control-tower runs.
- Issue #257: Cloudflare Tunnel currently has a control-plane-node availability dependency.

These do not invalidate the completed platform upgrade, but they are explicit resilience work for
the next lifecycle iteration.

## Documentation safety

Do not place public FQDNs, credentials, tokens, certificate material, tunnel identifiers, unseal
material, or other secrets in lifecycle documentation or GitHub issue examples. Use placeholders.
