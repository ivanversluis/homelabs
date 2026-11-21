# n8n: Kong AI Gateway connection and v3 migration runbook

**Status (2026-11-21):** n8n 3.x is early access; stable release is planned for early December 2026. Do not merge the separate v3 image PR until the gates below pass. This runbook applies first to the stable 2.x preparation PR.

## Source of truth

- n8n application: `workloads/apps/n8n/`; Flux: `compute/eliteboxes/workloads/n8n-kustomization.yaml`.
- PostgreSQL: `StatefulSet/n8n-postgres` (Postgres 16), data PVC `n8n-postgres-pvc`.
- Application data: `n8n-pvc` mounted at `/home/node/.n8n`.
- Both PVCs currently declare legacy `longhorn` (reclaim policy `Delete`), not `longhorn-worker`. Do **not** replace or rename them as part of the upgrade.
- Kong gateway: `services/gateway/kong/llm-gateway/`; DNS is split-brain for `llm-gw.${DOMAIN}`.
- The existing `allow-egress-to-kong` NetworkPolicy in the n8n namespace permits destination Kong pod ports `8000/8443`. No new broad egress policy is needed.

## Phase 1 — connect n8n to Kong (works on n8n 2.x)

Kong already serves an **OpenAI-compatible chat** API. n8n must use the internal Kong **client** key, not the Anthropic upstream key.

| Setting | Value |
| --- | --- |
| n8n credential type | `OpenAI` |
| Credential display name | `Kong AI Gateway` |
| Base URL | `https://llm-gw.<domain>/v1` (replace `<domain>` privately at runtime) |
| API key | Vault KV `secret/infra/kong`, property `AI_GATEWAY_CLIENT_KEY` |
| Organization ID | empty |
| Model ID | `claude-sonnet-4-6` |
| Supported operation | `POST /v1/chat/completions` |
| Model discovery | `GET /v1/models` |

Open **n8n → Credentials → Add credential → OpenAI**. Enter the key and Base URL, then save. An n8n OpenAI Chat Model node (or Basic LLM Chain / AI Agent with this model) can reuse this credential. Choose the model **By ID** if it does not appear in the list.

For OpenAI Chat Model nodes with a **Use Responses API** toggle, turn it **off**: this Kong route implements Chat Completions, not `/v1/responses`. Do not select n8n's own **Gateway credits** feature; that is unrelated to the self-hosted Kong gateway.

The Kong client secret is currently shared with Open WebUI and OpenClaw. Do not copy the key into Git, ConfigMaps, workflow JSON, shell history, or tickets. n8n stores a credential added through its UI encrypted in its database using `N8N_ENCRYPTION_KEY`. Kubernetes External Secrets does **not** automatically create an n8n UI credential; deliberately avoid global `CREDENTIALS_OVERWRITE_DATA` (it can override unrelated OpenAI credentials and expose secrets to workflows). For later isolation, create a dedicated KongConsumer and client key for n8n, using a separate bootstrap Secret reconciliation.

### Network-only test, without printing credentials

On a shell with `kubectl` access, resolve the private domain locally without displaying it:

```bash
DOMAIN="$(kubectl -n flux-system get secret flux-domain-vars -o jsonpath='{.data.DOMAIN}' | base64 -d)"
kubectl -n n8n exec deploy/n8n -- node -e '
const url = process.argv[1];
fetch(url).then(r => console.log("Gateway HTTP status:", r.status))
  .catch(e => { console.error(e.message); process.exit(1); });
' "https://llm-gw.${DOMAIN}/v1/models"
unset DOMAIN
```

**Expected: HTTP 401** (or another gateway authentication rejection) when the key is omitted. That proves DNS, TLS and routing reached Kong. DNS/TLS errors or a timeout indicate connectivity trouble. A 200 without a key requires investigation of Kong authentication. The authorized test happens in the n8n OpenAI credential and a manual test workflow.

## Phase 2 — prerequisites for major upgrade to v3

**Before merging the v2 preparation PR or any later image update**, verify recent and restorable PostgreSQL + application-PVC backups and the retained encryption key. Even a minor image change can run schema migrations. Make sure the live PersistentVolumes are protected by an appropriate reclaim policy. 

1. Upgrade stable v2 first to **2.48.7** and verify the service and important workflows.
2. In n8n go to **Settings → Migration Report**. Review both **Workflow issues** and **Instance issues**, resolve or explicitly triage findings, and test any automatically migrated workflows. Export the report for the change record.
3. Look for removed legacy nodes (Function / Function Item / Item Lists / Cron / older OpenAI nodes / older AI Agent types), incompatible expression helpers, custom/community nodes, and updated task-runner defaults.
4. Back up **both PVCs**, the **PostgreSQL database**, and securely retain the matching `N8N_ENCRYPTION_KEY` from Vault `secret/apps/n8n`. Confirm the Longhorn snapshots/backups exist off-cluster and restore a copy in a **network-isolated staging instance**. Do not allow cloned schedules and webhooks to contact external systems.
5. Verify both live PVs have `Retain` reclaim policy. The repository's `longhorn` PVCs otherwise risk deletion if an operator removes a PVC. Do not rely on `kustomize.toolkit.fluxcd.io/prune: disabled` alone.
6. Confirm free space in **both 250Mi PVCs**, including room for database migration and binary-data files. Resize in a separate, verified storage change if needed.
7. In the n8n data volume, check whether both `/home/node/.n8n/binaryData` and `/home/node/.n8n/storage` exist. n8n 3 refuses startup when both exist; `binaryData` is renamed to `storage` in the v3 migration.
8. Confirm the n8n image runs as UID/GID 1000 with the existing `fsGroup`, writable `/home/node/.n8n`, no new root init container, and successful `/healthz`. The startup probe tolerates slow migrations, but does **not** replace a backup.
9. Test v3 on the isolated restored copy **before** merging the v3 image PR. As of November 21, `3.3.0` is still a pre-release. Revisit the exact pinned image when stable 3.x is published.

### Read-only infrastructure checks

```bash
kubectl -n n8n get deployment n8n
kubectl -n n8n get statefulset n8n-postgres
kubectl -n n8n get pvc n8n-pvc n8n-postgres-pvc
kubectl -n n8n get externalsecret n8n-secrets n8n-postgres-secrets
kubectl -n n8n get networkpolicy allow-egress-to-kong
kubectl -n longhorn-system get backupvolumes.longhorn.io

for claim in n8n-pvc n8n-postgres-pvc; do
  pv="$(kubectl -n n8n get pvc "$claim" -o jsonpath='{.spec.volumeName}')"
  printf '%s: ' "$claim"
  kubectl get pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'
done
```

If a live PV still reports `Delete`, change its **PV** reclaim policy to `Retain` in a separately approved storage-safety operation; a PVC `storageClassName` cannot be edited in place. Validate backups first.

### PostgreSQL logical backup (run on a trusted admin host)

```bash
umask 077
kubectl -n n8n exec n8n-postgres-0 -- sh -c '
  export PGPASSWORD="$POSTGRES_PASSWORD"
  exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc
' > n8n-postgres-before-v3.dump
test -s n8n-postgres-before-v3.dump
pg_restore -l n8n-postgres-before-v3.dump >/dev/null
```

This protects the database only; also back up the application PVC and the encryption key. Verify a staging restore. Never store backup archives or credentials in Git.

## Phase 3 — validate after the v3 switch

```bash
kubectl -n flux-system get kustomization n8n
kubectl -n n8n rollout status deployment/n8n --timeout=10m
kubectl -n n8n logs deployment/n8n --tail=80
kubectl -n n8n get pods,pvc
```

Then validate n8n login, workflow listing, migration status, credentials, a scheduled trigger, a webhook, existing automation runs, and a manual OpenAI Chat Model call through Kong. For the latter use model `claude-sonnet-4-6`, **Responses API off**, and expect a real completion. A 401 usually means the wrong Kong **client** key; a 404 for `/v1/responses` usually means the wrong API mode; a timeout/DNS failure usually means network policy or split-horizon DNS; a 400 may indicate unsupported OpenAI request fields.

**Rollback:** before v3, a normal Git image revert can be considered. **After v3 has migrated the DB/filesystem, never simply change back to v2**. Stop the app and restore the pre-v3 PostgreSQL and n8n application-volume backups plus the matching encryption key; then deploy the previous v2 image. This requires a tested restore procedure.

References:
- https://docs.n8n.io/changelog/v30-breaking-changes/
- https://docs.n8n.io/changelog/v30-migration-tool/
- https://docs.n8n.io/integrations/builtin/credentials/openai/
- https://docs.n8n.io/hosting/installation/updating/
- `docs/lifecycle/anthropic-kong-ai-gateway.md`
- `platform/storage/README.md`
