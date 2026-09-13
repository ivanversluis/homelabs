# Wave 3 recovery checkpoint

Creates the mandatory fresh recovery point immediately before the Kubernetes control-plane minor upgrade.

It performs no drain, reboot, package upgrade, or Kubernetes version change. It:

- requires all Kubernetes nodes Ready;
- requires all Longhorn volumes healthy;
- requires Longhorn v1.12.1 and Calico v3.32.1;
- requires a configured Longhorn backup target;
- creates and checksum-verifies a fresh local etcd snapshot;
- creates a Longhorn `SystemBackup` with `volumeBackupPolicy: always` and waits for `Ready`;
- writes `/var/lib/homelab-backups/wave3-control-plane/latest-checkpoint.env`.

The subsequent control-plane upgrade accepts this checkpoint only while it is fresh (default: two hours).

Run:

```text
playbook=playbooks/66-wave3-recovery-checkpoint.yml
limit=k8s-master01
```
