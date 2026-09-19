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
3. Scale Vault back to 1 replica. It will start **sealed** — unseal it using
   `scripts/vault-post-deploy.sh <vault-keys-file>` or manually with `vault operator unseal`.
4. Verify with `vault status` and confirm expected secrets engines/policies are present
   before resuming ExternalSecrets traffic.

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
