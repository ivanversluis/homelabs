# Platform storage

Kubernetes storage components that provide persistent storage capabilities to workloads.

## Components

- `longhorn/` — distributed block storage and the primary persistent storage layer.
- `local-path-provisioner/` — node-local storage used by the KubeVirt lab workflow; retained declaratively for bootstrap/reference where documented.

These components are platform dependencies. Application PVCs and VM workloads remain outside this directory.
