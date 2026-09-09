# Wave -1 lifecycle handoff

## Status

Wave -1b completed successfully on 2026-09-09.

Verified backup directory on `k8s-master01`:

```text
/var/lib/homelab-backups/pre-maintenance/20260909T144749Z
```

The completed run validated:

- etcd snapshot (`148 MB`, revision `98759609`, 3744 keys, etcd 3.6.0)
- PostgreSQL logical dumps for Firewall Manager dev/staging/prod, Authentik, n8n and SemaphoreUI
- all selected Bound PVC archives
- native Prometheus TSDB snapshot and archive
- Vault filesystem backup while the Vault StatefulSet was offline
- SHA-256 checksums for all artifacts
- archive readability and etcd snapshot verification

`vms/debian-bookworm-dv` was deliberately excluded.

## Required offsite gate

Before Wave -1c live activation:

1. Copy the complete backup directory to Synology.
2. From the Synology copy, run:

```bash
cd <copied-backup-directory>
sha256sum -c SHA256SUMS
```

3. Preserve both the master-node copy and Synology copy until the maintenance program is complete.

## Repository implementation

Run the Copilot prompt:

```text
/wave-minus1-control-tower
```

or open `.github/prompts/wave-minus1-control-tower.prompt.md` and run it with GitHub Copilot Agent mode.

The first Copilot pass is repository-only. It must build and validate the Ansible/Semaphore/Vault SSH lifecycle foundation without activating it live.

## Live activation gate

After the repository-only implementation is merged/pushed and Synology checksums have passed, explicitly start the next phase with:

```text
Wave -1c live activation approved. Re-read .github/prompts/wave-minus1-control-tower.prompt.md, validate current main and live cluster state, then execute only Wave -1c and Wave -1d. Stop on any failed recovery/SSH validation and report before continuing.
```

## Post-activation backup

After Vault begins holding the SSH CA private key, create another Vault checkpoint backup and copy it offsite. The original pre-change Wave -1b backup must remain retained as the clean rollback checkpoint.
