# Restore runbook

Restore procedures for the artifacts captured by the Wave -1b pre-maintenance backup. This
runbook assumes the backup has already passed its offsite integrity gate:

```text
/var/lib/homelab-backups/pre-maintenance/20260909T144749Z   (on k8s-master01)
```

Before using this runbook, confirm both copies still exist and the Synology copy passed:

```bash
cd <copied-backup-directory>
sha256sum -c SHA256SUMS
```

Never restore from a copy that failed its checksum verification.

## What the Wave -1b backup contains

- etcd snapshot (148 MB, revision `98759609`, 3744 keys, etcd 3.6.0)
- PostgreSQL logical dumps: Firewall Manager dev/staging/prod, Authentik, n8n, SemaphoreUI
- Bound PVC archives (selected applications)
- Native Prometheus TSDB snapshot/archive
- Vault filesystem backup (captured while the Vault StatefulSet was offline)
- SHA-256 checksums for every artifact

`vms/debian-bookworm-dv` was deliberately excluded from this backup and is not covered by
this runbook.

## etcd restore

1. Stop the kube-apiserver/etcd static pods on `k8s-master01` (move the manifest files out of
   `/etc/kubernetes/manifests/` temporarily).
2. Restore the snapshot to a fresh data directory:
   ```bash
   etcdutl snapshot restore <snapshot-file> \
     --data-dir /var/lib/etcd-restored \
     --name k8s-master01 \
     --initial-cluster k8s-master01=https://172.16.20.200:2380 \
     --initial-advertise-peer-urls https://172.16.20.200:2380
   ```
3. Point etcd's static pod manifest at the restored data directory, move manifests back into
   place, and wait for `kube-apiserver`/`etcd` to come back healthy.
4. Verify with `etcdutl snapshot status` and `kubectl get nodes`/`kubectl get pods -A` before
   declaring the restore complete.

## PostgreSQL logical restore (per application)

```bash
# Example: Authentik
kubectl exec -n identity postgresql-0 -- \
  psql -U "$PG_USER" -d "$PG_DB" -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'
cat authentik-dump.sql | kubectl exec -i -n identity postgresql-0 -- \
  psql -U "$PG_USER" -d "$PG_DB"
```

Repeat per application (Firewall Manager dev/staging/prod, n8n, SemaphoreUI) using that
application's namespace, pod, and credentials. Restore into a scratch namespace first if the
target application is expected to keep serving traffic during validation.

## PVC restore

Bound PVC archives were captured as tarballs. To restore one:

1. Scale the owning workload to 0 replicas.
2. Copy the archive into a temporary pod mounting the same PVC, and extract it, replacing the
   PVC's contents.
3. Scale the workload back up and verify application-level health before resuming traffic.

## Vault filesystem restore

The Vault backup was captured **while the Vault StatefulSet was offline**, so it is a
consistent file-storage snapshot of `/vault/data`.

1. Scale the Vault StatefulSet to 0 replicas.
2. Replace the contents of the Vault PVC with the backed-up `/vault/data` contents.
3. Scale Vault back to 1 replica. Inspect `vault status`: for the **existing** file backend, `Initialized=true` and `Sealed=true` means the original state is present; unseal interactively with the independently held original Shamir shares using `kubectl -n vault exec -it vault-0 -c vault -- vault operator unseal` (repeat with distinct shares until threshold). **If `Initialized=false`, STOP**: do not run `operator init`.
4. Verify unsealed status, the expected secret engines, policies, SSH CA signer and ESO/Semaphore integration before resuming dependent traffic. **Do not use** legacy `scripts/vault-post-deploy.sh` for migration or recovery; it is a single-pod bootstrap script with sensitive key/token handling and automatic initialization behavior, not a safe HA recovery workflow.

## Vault after the Raft cutover (future state, not yet active)

The preceding **Vault filesystem restore** applies ONLY to the current standalone `file` backend and preserved pre-migration rollback. Once issue #256 completes the cutover, DO NOT tar a mounted Raft directory or restore a raw filesystem archive over a running Raft cluster.

- Backup: from an **authenticated, unsealed leader** use `vault operator raft snapshot save <local-snapshot.snap>` on a trusted independent admin client. Never place tokens in arguments/history. Compute `sha256sum <local-snapshot.snap>`, transfer securely to independent off-cluster storage (e.g. Synology), and verify its checksum at the destination. Snapshot archives contain highly sensitive Vault data; encrypt and restrict access outside Vault/ESO/Semaphore.
- Automation: daily off-cluster snapshots, failure alerting, documented credential rotation, retention and **isolated restore testing** are required before claiming a 24h RPO. Longhorn PVC backups are useful secondary disaster recovery, but **not a substitute** for application-consistent Vault Raft snapshots. This PR does not deploy the scheduled snapshot workflow.
- Restore: provision an **empty isolated Raft recovery cluster**, initialize it with **temporary target** Shamir shares, unseal/authenticate, securely copy+checksum the verified snapshot, and follow [HashiCorp's snapshot restore procedure](https://developer.hashicorp.com/vault/docs/sysadmin/snapshots/restore). For restoring a snapshot **from a different cluster with different Shamir/unseal keys**, HashiCorp explicitly requires `vault operator raft snapshot restore -force`; this bypasses seal-key consistency checks, so it is permitted only after *independent* namespace/cluster identity and backup verification, never as a generic recovery shortcut. It is asynchronous: the restore command returning does **not** prove completion. After restoration, use the **original snapshot-source shares**, not the temporary target shares. A 3-voter snapshot on a 1-node disposable target can require carefully planned isolated [lost-quorum recovery](https://developer.hashicorp.com/vault/tutorials/raft/raft-lost-quorum). Verify actual logs, Raft quorum, KV/policy/SSH CA signer fingerprint and seals before claiming restored state; the isolated restore test must not rejoin the source cluster.
- Disaster recovery: a new empty Raft cluster is **not** an in-place continuation of the retained standalone PV. During the agreed rollback window, restore the old retained local-path PV and prior chart configuration as described in [vault-raft-migration.md](./vault-raft-migration.md), accepting loss of writes since cutover unless reconciled.

**2026-10-19 status:** Synthetic Raft snapshot export and workstation SHA-256 verification **passed**; a separate restore-test instance with its own Longhorn PVC exists but remains **uninitialized and sealed**. No snapshot restore or production rollback has been executed. See the [comprehensive operator evidence and resumption guide](./vault-raft-migration-rehearsal-2026-10-19.md) and the [production cutover gates](./vault-raft-migration.md). Production still runs the file backend. Do not restore into `vault` or the healthy three-node `vault-raft-rehearsal` instance.

## Post-Wave -1c checkpoint backup

Once Vault begins holding the SSH CA private key (after `vault-ca` activation), take a new
Vault filesystem checkpoint backup and copy it offsite, following the same procedure as the
Wave -1b backup. Do not delete or overwrite the original Wave -1b backup — it remains the
clean pre-maintenance rollback point for the whole program, independent of the control tower.

## Validation after any restore

Run, at minimum:

```bash
kubectl get nodes
kubectl get pods -A | grep -v Running
./scripts/zero-trust-validate.sh --quick
./scripts/lifecycle/validate-control-tower.sh --quick
```

Escalate to a full (non `--quick`) validation run before considering the restore complete.
