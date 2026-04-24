# Semaphore UI Homelab wiki

## Documentation
https://artifacthub.io/packages/helm/semaphoreui/semaphore

## Repo
https://github.com/semaphoreui/semaphore
https://github.com/semaphoreui/charts

## Releases
https://github.com/semaphoreui/charts/releases

## Latest version
Chart: 16.0.11
App: 2.16.47
Image: semaphoreui/semaphore:v2.16.47

## Objective
As home-admin I want to run Ansible and related automation jobs from a self-hosted web UI with persistent state.

## Implementation
Semaphore UI is deployed on Kubernetes with Flux CD using the official Helm chart backed by a PostgreSQL database. Secrets are sourced from Vault through ExternalSecrets and no plaintext credentials are stored in manifests.

## Stack
- Flux CD HelmRelease + HelmRepository
- PostgreSQL 16.11 (StatefulSet with 250Mi PVC)
- Longhorn persistent storage
- ExternalSecrets (Vault-backed)
- ClusterSecretStore authentication

## LLD

### Namespace
`semaphoreui`

### Service
`semaphoreui` (ClusterIP, port 3000)

### Database Backend
PostgreSQL 16.11 (StatefulSet)
- Service: `semaphoreui-postgres` (ClusterIP, port 5432)
- Storage: Longhorn 250Mi PVC
- User: semaphoreui (dynamically created via ExternalSecret)

### Workdir Storage
250Mi Longhorn PVC for temporary task files

### Vault Secrets Path
`infra/semaphoreui`

### Required Vault Properties
Admin credentials:
- `SEMAPHORE_ADMIN_USERNAME`
- `SEMAPHORE_ADMIN_PASSWORD`
- `SEMAPHORE_ADMIN_EMAIL`
- `SEMAPHORE_ADMIN_FULLNAME`

Database credentials:
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`
- `POSTGRES_DB`

Application secrets:
- `SEMAPHORE_COOKIE_HASH`
- `SEMAPHORE_COOKIE_ENCRYPTION`
- `SEMAPHORE_ACCESS_KEY_ENCRYPTION`
- `SEMAPHORE_RUNNER_TOKEN`

See `semaphore-ui-secrets.md-local` for secure generation instructions.
