# Platform storage

Kubernetes storage components that provide persistent storage capabilities to workloads.

## Components

- `longhorn/` — distributed block storage and the primary persistent storage layer.
- `local-path-provisioner/` — node-local storage used by the KubeVirt lab workflow; retained declaratively for bootstrap/reference where documented.

These components are platform dependencies. Application PVCs and VM workloads remain outside this directory.

## Longhorn layout

| Path | Flux Kustomization | Purpose |
|---|---|---|
| `longhorn/k8s/` | `longhorn` | Vendored Longhorn v1.12.1, settings patches, `longhorn-worker` StorageClass |
| `longhorn/recurring-jobs/` | `longhorn-recurring-jobs` (dependsOn `longhorn`) | Scheduled backups to the backup target |
| `longhorn/oauth2-proxy/` | `longhorn-ingress` (dependsOn `longhorn`, `kong`; `${DOMAIN}` substitution) | Authenticated UI at `storage.${DOMAIN}` using the shared oauth2-proxy base |

`recurring-jobs/` and `oauth2-proxy/` are separate reconciliation boundaries because their resources are
validated by admission webhooks (Longhorn, Kong) that only exist after their dependencies are ready.

## StorageClasses

| Class | Reclaim policy | Notes |
|---|---|---|
| `longhorn-worker` | **Retain** | Cluster default. Use for all stateful workloads. |
| `longhorn` | Delete | Legacy/compatibility. Deleting the PVC **deletes the data**. |

PVCs that still use `longhorn` must have their PV patched to `Retain`:

```sh
kubectl patch pv <pv-name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

Migrating a PVC to `longhorn-worker` requires `scripts/lifecycle/storage-class-migration.sh`
(`storageClassName` is immutable).

## Backups

Backup target: NFS on the Synology NAS (configured in Longhorn settings, `default` backup target).

| RecurringJob | Schedule (UTC) | Retain |
|---|---|---|
| `backup-daily` | `0 1 * * *` | 7 |
| `backup-weekly` | `0 3 * * 0` (Sunday) | 4 |
| `backup-monthly` | `0 4 1 * *` (1st of month) | 6 |

All jobs target the `default` group, which contains every volume that has no explicit
recurring-job label — new PVCs are covered automatically.

Verify:

```sh
kubectl get recurringjobs.longhorn.io -n longhorn-system
kubectl get backupvolumes.longhorn.io -n longhorn-system   # LASTBACKUPAT per volume
```

Restore: Longhorn UI → Backup → select backup → *Restore* to a new volume, then bind a PVC to it
(or use *Create PV/PVC*). Test a restore periodically — an untested backup is not a backup.

## Protecting data from GitOps

Lesson from the 2026-08-30 n8n data loss: a forced re-apply deleted and recreated
`n8n-postgres-pvc`; with `reclaimPolicy: Delete` Longhorn deleted the volume, and no backups existed.

For every stateful PVC:

1. Use `longhorn-worker` (Retain) or patch the PV to `Retain`.
2. Annotate the PVC with `kustomize.toolkit.fluxcd.io/prune: disabled`.
3. Never reconcile PVCs through a Flux Kustomization with `force: true`.
4. Ensure the volume appears in `backupvolumes.longhorn.io`.

## UI access and authentication

Longhorn has no built-in authentication or OIDC support; the UI and its API are fully privileged
for anyone who can reach `longhorn-frontend`. Access is therefore layered:

```text
Internet ─► Cloudflare Access ─► cloudflared ─┐
LAN ─────────────────────────────────────────┴► Kong ─► longhorn-oauth2-proxy ─► longhorn-frontend
                                                         (Authentik OIDC,          (NetworkPolicy: only
                                                          group "Longhorn Admins")  oauth2-proxy allowed)
```

- **oauth2-proxy** (`longhorn/oauth2-proxy/`) performs the OIDC login against Authentik
  (`https://auth.${DOMAIN}/application/o/longhorn/`) and only admits members of `Longhorn Admins`.
  The Deployment and Service come from `platform/security/oauth2-proxy/base`; the Longhorn overlay only
  supplies issuer, callback, upstream, group, cookie and secret wiring. Kong OSS does not ship the
  `openid-connect` plugin (Enterprise-only), which is why the proxy layer is required.
- **Credentials**: Vault `infra/longhorn` (`OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`,
  `OAUTH2_PROXY_COOKIE_SECRET`), written by Terraform
  (`automation/infra-as-code/terraform/deployments/longhorn`) and synced by the
  `longhorn-oidc` ExternalSecret.
- **NetworkPolicies**: `longhorn-ui` accepts traffic only from `longhorn-oauth2-proxy`;
  oauth2-proxy accepts traffic only from the `kong` namespace.
- **Emergency access**: `kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80`.

## Domain (`${DOMAIN}`)

`${DOMAIN}` is never hardcoded. Sources:

| Consumer | Source |
|---|---|
| Flux manifests | `flux-domain-vars` Secret ← ExternalSecret `infra/flux-substitution/` ← Vault `secret/infra/kong-manifests-openui-gateway-mcp`, property `domain` |
| Terraform (Authentik redirect URIs, Cloudflare routes/Access) | `var.domain` in `automation/infra-as-code/terraform/deployments` (tfvars) |
| Scripts / Makefile | `kubectl get secret flux-domain-vars -n flux-system -o jsonpath='{.data.DOMAIN}' \| base64 -d` |

Only Flux Kustomizations with `postBuild.substituteFrom: flux-domain-vars` substitute `${DOMAIN}`.
