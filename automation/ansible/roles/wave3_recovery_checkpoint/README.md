# wave3_recovery_checkpoint

Creates the mandatory fresh recovery point before a coordinated control-plane mutation or host
reboot.

It performs no drain, reboot, package upgrade, or Kubernetes version change. It:

- requires all Kubernetes nodes Ready;
- requires all Longhorn volumes healthy;
- requires the centrally configured Longhorn and Calico baseline;
- requires Longhorn `BackupTarget/default` to have a non-empty URL and `available=true`;
- creates and checksum-verifies a fresh local etcd snapshot;
- creates a Longhorn `SystemBackup` with `volumeBackupPolicy: always` and waits for `Ready`;
- writes `/var/lib/homelab-backups/wave3-control-plane/latest-checkpoint.env`.

The legacy `wave3` path is retained for compatibility. The subsequent control-plane operation
accepts the checkpoint only while it is fresh (default: two hours).

Run:

```text
playbook=playbooks/66-wave3-recovery-checkpoint.yml
limit=k8s-master01
```

For recurring maintenance, run this checkpoint both before playbook 67 and again immediately before
playbook 70.
