# Storage (Longhorn) Homelab wiki

## Documentation
https://longhorn.io/docs/

## Repo
https://github.com/longhorn/longhorn

## Releases
https://github.com/longhorn/longhorn/releases

## Latest version
v1.11.0

## Objective
As home-admin I want distributed block storage for Kubernetes so that PersistentVolumeClaims are replicated across nodes with backup and snapshot capabilities.

## Implementation
Deployed from upstream Longhorn manifests via Kustomize with strategic merge patches for default settings, StorageClass configuration, and hotfixes.

## Stack
Upstream manifests + Kustomize patches (via Flux)

## LLD
- Namespace: longhorn-system
- Version: v1.11.0
- StorageClass: longhorn (default)
- Patches: default-setting, storageclass, manager-hotfix, driver-deployer-hotfix
- Node selector: node.longhorn.io/create-default-disk=true
- Dependencies: None (foundational storage)
