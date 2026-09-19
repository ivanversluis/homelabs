# longhorn_upgrade

Read-only Wave 1 preparation gate for the supported Longhorn v1.11.x to v1.12.1 upgrade.
It inventories manager/driver images, volumes, replicas, engines, V1/V2 state,
BackingImages, backup targets, system/volume backups, and StorageClasses. It never creates a
backup or changes a Kubernetes object.

The gate requires a `Ready` Longhorn SystemBackup no older than 24 hours whose
`volumeBackupPolicy` is `always`. The separate off-cluster Synology archive remains part of
disaster recovery, but it does not replace Longhorn's own system-and-volume backup gate.

Run through the existing Semaphore control-tower runner:

```text
playbook=playbooks/55-longhorn-upgrade-preparation.yml
limit=k8s_homelab
```

A successful `READY FOR APPROVAL` result authorizes review, not execution. The active
Kustomization must not be changed until the operator explicitly approves Wave 1 execution.
