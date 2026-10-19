# HashiCorp Vault — homelab service

## Sources

- [HashiCorp Vault documentation](https://developer.hashicorp.com/vault/docs)
- [HashiCorp Vault chart](https://artifacthub.io/packages/helm/hashicorp/vault)
- [Issue #256 — deterministic Vault recovery](https://github.com/ivanversluis/homelabs/issues/256)
- [Production migration design and gates](../../docs/lifecycle/vault-raft-migration.md)
- [Comprehensive 2026-10-19 rehearsal report / overnight handover](../../docs/lifecycle/vault-raft-migration-rehearsal-2026-10-19.md)
- [Synthetic step-by-step rehearsal](./candidates/raft-ha/rehearsal/README.md)

## Objective

Provide centralized secrets and short-lived SSH signing for applications, External Secrets Operator (ESO) and the Semaphore/Ansible control tower. Vault is foundational infrastructure, so independent break-glass access and backups must work when Vault is sealed or unreachable.

## Production implementation — still active and unchanged

- **GitOps:** `infra/vault/helmrelease.yaml`, reconciled by Flux.
- **Namespace:** `vault`; chart pinned to **0.34.1** in current Git. This is the *declared deployed chart version*, not a claim about the newest upstream release.
- **Mode:** one standalone Vault server, **file backend** at `/vault/data`, RWO PVC (10Gi).
- **StorageClass in Git:** `null` (inherits current default on claim creation); the existing PVC's actual class must be queried live. Operator-reported preflight for #256 indicates the older existing production PV is `local-path` with `Retain`.
- **Networking:** API TCP 8200 (ClusterIP); UI enabled; telemetry retention 12h.
- **Seal:** manual Shamir after restart; there is no approved production auto-unseal design.
- **Status:** production storage, service wiring and seal configuration are **NOT** migrated by PR #355.

## Candidate HA architecture — GitOps excluded

`infra/vault/candidates/raft-ha/helmrelease.yaml` defines a proposed 3-member Vault 2.0.4 integrated Raft cluster, Longhorn worker-specific RWO 10Gi claims, three-worker anti-affinity, a PDB and operator-assisted manual unseal. The review branch also adds a non-root initialization container for `/vault/data/raft` on fresh PVCs.

The **synthetic** rehearsal on 19 October 2026 proved migration data integrity, all three voters, automated leader election under one node loss, recovery, and verified off-cluster Raft snapshot export. The **disposable restore target** is safely left `Initialized=false`, `Sealed=true`; snapshot restoration has **not** been performed.

**Open production gates:** isolated snapshot restoration, retained-file rollback, probe/startup recovery, production ESO/Kubernetes auth/Semaphore integration, daily independent snapshot automation, approved RTO/RPO, key custody and maintenance signoff. See the [migration guide](../../docs/lifecycle/vault-raft-migration.md).

## Operator safety

Never initialize Vault just because its pod is unready. Distinguish `Sealed=true` from `Initialized=false`; do not delete the old PVC/PV or run `vault operator migrate` over initialized Raft data. Keep Shamir shares/tokens and Vault backup contents outside Git, tickets, chat and command arguments. The legacy `scripts/vault-post-deploy.sh` is a bootstrap script and must not be used for the Raft cutover or failover recovery.
