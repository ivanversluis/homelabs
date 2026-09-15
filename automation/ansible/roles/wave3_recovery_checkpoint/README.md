# Wave 3 recovery checkpoint

Creates the mandatory fresh recovery point immediately before the Kubernetes control-plane minor upgrade.

It performs no drain, reboot, package upgrade, or Kubernetes version change. It:

- requires all Kubernetes nodes Ready;
- requires all Longhorn volumes healthy;
- requires Longhorn v1.12.1 and Calico v3.32.1;
- requires Longhorn `BackupTarget/default` to have a non-empty URL and `available=true`;
- creates and checksum-verifies a fresh local etcd snapshot;
- calculates the checkpoint timestamp, etcd snapshot path, and SystemBackup name once as deterministic Ansible facts, avoiding cross-task parsing of SSH stdout;
- creates a Longhorn `SystemBackup` with `volumeBackupPolicy: always` and waits for `Ready`;
- writes `/var/lib/homelab-backups/wave3-control-plane/latest-checkpoint.env`.

The subsequent control-plane upgrade accepts this checkpoint only while it is fresh (default: two hours).

Run:

```text
playbook=playbooks/66-wave3-recovery-checkpoint.yml
limit=k8s-master01
```
