# Raspberry Pi 4

Reserved for the planned Pi4 rebuild with Kubernetes, Flux, and Semaphore maintenance. This directory is documentation only until the Kubernetes bootstrap configuration is reviewed and committed.

## Onboarding sequence

1. Record the Pi4 hostname, address, storage, ARM64 operating system, Kubernetes distribution/version, and recovery procedure before reimaging.
2. Install Kubernetes and validate networking, storage, DNS, time synchronization, and cluster access. Use ARM64-compatible images and environment-specific configuration.
3. Add a Pi4-only `kustomization.yaml` and reviewed platform/service selections. Do not copy the complete EliteBox root: its storage, node addresses, networking, and workload assumptions are environment-specific.
4. Bootstrap Flux into the Pi4 cluster with repository path `compute/pi4`. Give it its own source credentials and required substitution/secrets configuration. Confirm it cannot reconcile `compute/eliteboxes` or `compute/synology`.
5. Add Pi4 inventory/host trust, Vault SSH signing authorization, narrowly scoped network access, and explicit target support in the Semaphore runner. Use separate maintenance templates and schedules suited to the selected OS/runtime.
6. Validate read-only preflight, backups, disk/memory/CPU alerting, then one manual maintenance run before enabling schedules.

The current `k8s_homelab` inventory and four-node Semaphore maintenance jobs remain scoped to the EliteBox cluster. See [the shared onboarding guidance](../../docs/lifecycle/compute-layout-migration.md#future-pi4-and-synology-onboarding).
