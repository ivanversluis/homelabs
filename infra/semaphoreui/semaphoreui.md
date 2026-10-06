# Semaphore UI Homelab wiki

## Documentation
https://docs.semaphoreui.com/

## Repo
https://github.com/semaphoreui/semaphore

## Releases
https://artifacthub.io/packages/helm/semaphoreui/semaphore

## Latest version
v2.18.2 (Helm chart 16.1.2)

## Objective
As home-admin I want a self-hosted Ansible/Terraform UI to run automation playbooks, manage inventories, and schedule infrastructure tasks with a web interface.

## Implementation
Deployed via Flux HelmRelease with a dedicated PostgreSQL database. Secrets managed via ExternalSecret operator backed by Vault.

## Stack
Helm (FluxCD HelmRelease)

## Operational schedules

Semaphore evaluates recurring jobs in `Europe/Amsterdam`. The weekly containerd image cleanup is
managed by `scripts/lifecycle/configure-semaphore-image-prune.sh` and runs Sunday at 04:00 by
default. See `docs/lifecycle/containerd-image-prune.md` for provisioning and manual-run details.

## LLD
- Namespace: semaphoreui
- Image: semaphoreui/semaphore:v2.18.2
- Helm chart: semaphore v16.1.2
- Service: ClusterIP
- Storage: 250Mi PVC (Longhorn)
- Database: PostgreSQL (separate deployment in same namespace)
- Dependencies: ExternalSecret (Vault) for Postgres credentials
