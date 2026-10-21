# Terraform in Semaphore UI: migration runbook

Moves the Terraform root `automation/infra-as-code/terraform/deployments` (Authentik OIDC apps,
Cloudflare tunnel/Access, Vault app secrets) from a laptop/WSL working directory to Semaphore UI.
Everything marked **(you)** is a manual operator step. Nothing here changes Terraform-managed
infrastructure until you confirm an apply in step 6.

No private values (domain, tokens, IDs) belong in this repository, in this runbook, in shell
history or in chat. Commands below read secrets silently or from stdin.

## What the PR changes

| Area | Change |
|---|---|
| State | New 1Gi Longhorn PVC `semaphoreui-terraform-state` mounted at `/var/lib/terraform-state` (covered by the Longhorn `default` backup group). `versions.tf` uses `backend "local"` with `/var/lib/terraform-state/homelab/terraform.tfstate`. |
| Terraform binary | The Semaphore image bundles Terraform 1.11, but the state was written by 1.15.x and older binaries refuse it. An init container installs the pinned, checksum-verified Terraform 1.15.9 into `/opt/terraform-bin`; `SEMAPHORE_APPS` points the Terraform app at it. |
| Inputs | Vault `secret/infra/terraform` -> ESO -> Secret `semaphoreui-terraform-env` (`TF_VAR_*`), plus ConfigMap `semaphoreui-terraform-config`. `config.forwarded_env_vars` copies them into task runs. |
| Vault login | Terraform logs in with the pod service account (`terraform-semaphore` Kubernetes-auth role) instead of a static `vault_token`. |
| Provider lock | `.terraform.lock.hcl` is now committed so Semaphore uses the same provider versions as before (authentik 2026.2.0, cloudflare 5.19.1, vault 4.8.0, random 3.9.0). |
| Hostname | `demo-argocd` -> `argocd` in Terraform, tunnel config and helper scripts, so the first apply does not revert the live ArgoCD host. |

### Known hazard: Vault secrets are overwritten, not patched

`vault_generic_secret` rewrites the whole secret and creates a new KV version. These paths contain
keys that Terraform does not manage, so an apply that touches them would wipe those keys:

| Vault path | Keys Terraform would wipe (read by ESO) |
|---|---|
| `infra/semaphoreui` | admin credentials, cookie/encryption keys, runner token, Postgres credentials |
| `infra/argocd` | `REPO_*`, `github-registry-firewall-manager_*` |
| `infra/openwebui` | `admin-email`, `admin-password`, `mcp-consumer-key` |
| `apps/forgejo` | `FORGEJO__*` secrets |
| `apps/n8n` | DB, basic-auth and encryption keys |
| `apps/vaultwarden` | `ADMIN_TOKEN` |

Until the module is fixed (follow-up PR), the `terraform-semaphore` Vault policy **denies writes to
exactly these six paths**. A plan that wants to update them fails loudly with HTTP 403 instead of
deleting keys. Do not remove the deny rules before the module preserves foreign keys.

## 1. Before merging (you)

### 1.1 Verify the state backup

```bash
cd automation/infra-as-code/terraform/deployments
python3 -c "import json;d=json.load(open('terraform.tfstate'));print(d['serial'],d['lineage'][:8],d['terraform_version'],len(d['resources']))"
sha256sum terraform.tfstate
```

Keep a copy of the file and its checksum outside the repository (it contains plaintext provider
secrets). Never commit it.

### 1.2 New Cloudflare API token

Create an API token (account-owned) with the permissions Terraform uses and nothing else:

- Account > Cloudflare Tunnel > Edit
- Account > Access: Apps and Policies > Edit
- Zone > DNS > Edit, restricted to your zone

Also rotate the Authentik API token and the old Vault token that were in `terraform.tfvars`.

### 1.3 Vault policy and role

Run from the repository root (works in bash and zsh; the token is not echoed or stored in history):

```bash
cd "$(git rev-parse --show-toplevel)"
printf 'Vault admin token: '; stty -echo; read -r VT; stty echo; echo
[ -n "$VT" ] || echo "token is empty, stop"
vrun() { { printf '%s\n' "$VT"; cat; } | kubectl -n vault exec -i vault-0 -- \
  sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"' sh "$@"; }

vrun token lookup < /dev/null | grep -E '^(policies|ttl)'   # must list root/admin policies

vrun policy write terraform-semaphore - \
  < automation/infra-as-code/terraform/bootstrap/terraform-semaphore.hcl

vrun write auth/kubernetes/role/terraform-semaphore \
  bound_service_account_names=semaphore-ansible \
  bound_service_account_namespaces=semaphoreui \
  policies=terraform-semaphore ttl=2h max_ttl=4h < /dev/null

vrun read auth/kubernetes/role/terraform-semaphore < /dev/null | grep -E 'policies|bound_service'
```

`403 permission denied` means the token is empty or lacks admin rights (check the `token lookup`
line). `no such file` means you are not in the repository root.

The role uses the existing `semaphore-ansible` service account (the same identity as the SSH
certificate role), so any Semaphore task can obtain either role.

### 1.4 Seed `secret/infra/terraform`

```bash
cd "$(git rev-parse --show-toplevel)"/automation/infra-as-code/terraform/bootstrap
./seed-vault-from-tfvars.sh --dry-run ../deployments/terraform.tfvars   # review key sources
./seed-vault-from-tfvars.sh ../deployments/terraform.tfvars
```

The script copies the non-Vault variables from your tfvars, carries over the current Gatus tokens
and the Vault Prometheus token from their existing secrets (so Terraform does not overwrite them
with empty strings) and prints only key names. It refuses to overwrite an existing secret without
`--force`.

Store the new Cloudflare token with a **patch** so the other keys stay untouched:

```bash
printf 'Cloudflare API token: '; stty -echo; read -r CF; stty echo; echo
printf '{"cloudflare_api_token":"%s"}' "$CF" | vrun kv patch -mount=secret infra/terraform -
unset CF VT
```

Check the token before using it (replace `<ACCOUNT_ID>`): 
`curl -s -H "Authorization: Bearer $TOKEN" https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/tokens/verify`

### Vault variable reference (`secret/infra/terraform`)

| Vault key | Terraform variable | Required |
|---|---|---|
| `domain` | `domain` | yes |
| `authentik_url`, `authentik_token` | same | yes |
| `cloudflare_api_token`, `cloudflare_account_id`, `cloudflare_tunnel_id`, `cloudflare_team_name`, `cloudflare_zone_id` | same | yes |
| `vault_prometheus_metrics_token` | same | yes (current value of `infra/vault` key `prometheus-metrics-token`) |
| `gatus_discord_webhook_url`, `gatus_portainer_monitor_token`, `gatus_gitlab_monitor_token` | same | current values of `infra/gatus`, empty string = disabled |

Non-secret settings live in ConfigMap `semaphoreui-terraform-config`: `TF_VAR_vault_address`,
`TF_VAR_vault_kubernetes_role`, `TF_IN_AUTOMATION`, `SEMAPHORE_APPS`.

## 2. Merge and let Flux apply

Merge the PR, then:

```bash
flux reconcile kustomization semaphoreui -n flux-system --with-source
kubectl -n semaphoreui get pvc semaphoreui-terraform-state          # Bound
kubectl -n semaphoreui get externalsecret semaphoreui-terraform-env # SecretSynced
kubectl -n semaphoreui rollout restart deploy/semaphoreui           # envFrom is read at start
kubectl -n semaphoreui rollout status deploy/semaphoreui
kubectl -n semaphoreui logs deploy/semaphoreui -c install-terraform  # Terraform v1.15.9
```

The placeholder Secret guarantees Semaphore starts even if Vault was not seeded yet; in that case
the ExternalSecret shows an error until step 1.4 is done. Restart once more after fixing it.

## 3. Copy the state into the PVC (you)

Do this **before the first Terraform run**. An empty state would make Terraform plan to recreate
everything.

```bash
POD=$(kubectl -n semaphoreui get pod -l app.kubernetes.io/name=semaphore -o jsonpath='{.items[0].metadata.name}')
kubectl -n semaphoreui exec "$POD" -c semaphore -- mkdir -p /var/lib/terraform-state/homelab
kubectl -n semaphoreui cp -c semaphore \
  automation/infra-as-code/terraform/deployments/terraform.tfstate \
  semaphoreui/"$POD":/var/lib/terraform-state/homelab/terraform.tfstate
kubectl -n semaphoreui exec "$POD" -c semaphore -- sha256sum /var/lib/terraform-state/homelab/terraform.tfstate
sha256sum automation/infra-as-code/terraform/deployments/terraform.tfstate   # must match
kubectl -n semaphoreui exec "$POD" -c semaphore -- \
  /opt/terraform-bin/terraform state list -state=/var/lib/terraform-state/homelab/terraform.tfstate | wc -l
```

Expect checksums to match and a non-zero resource count (about 230).

## 4. Configure Semaphore UI (you)

1. **Key Store**: add a read-only credential for `github.com/ivanversluis/homelabs` (deploy key or
   fine-grained read-only token).
2. **Repository**: URL of the repo, branch `main`, the key from step 1.
3. **Environment**: create `terraform` with empty JSON `{}`. All inputs already come from the pod.
4. **Task template** `Terraform deployments`: app *Terraform Code*, the repository and environment
   above, subdirectory `automation/infra-as-code/terraform/deployments`, **auto-approve off**,
   destroy off.
5. **Applications** (account menu): the Terraform app path must read `/opt/terraform-bin/terraform`.
   It is set through `SEMAPHORE_APPS`; if it shows empty or the task log reports Terraform 1.11,
   set the path here manually.

## 5. First run: plan only (you)

Run the template and **stop at the confirmation prompt**. The task log must show Terraform
1.15.9, `Initializing the backend` with the local backend and `Refreshing state...` (not
"will be created" for everything). If Terraform says the state is newer than the binary, step 4.5
is not in effect.

The plan should match the drift already seen on the WSL run: Authentik apps/providers (domain and
hostname changes), the `email_verified` property mapping, Cloudflare tunnel ingress, Cloudflare
Access apps for Homepage and Longhorn, new Gatus resources, and new random secrets for Homepage,
Longhorn and Gatus. Review before applying:

- **Cloudflare Access (Longhorn/Homepage):** the plan removes a live policy that is not in the
  configuration (for example a `bypass` policy). If it was added by hand, add it to the Terraform
  config first or accept its removal deliberately.
- **Tunnel ingress:** confirm `argocd.<domain>` is in the planned ingress and `demo-argocd` is gone.
- **Vault:** only `infra/gatus` and `apps/homepage` secrets should be written. Any 403 on the six
  guarded paths means the plan touches a path the module cannot safely update yet.
- **New random secrets:** the Homepage auth secret and the oauth2-proxy cookie secrets rotate, which
  logs users out of those apps.

## 6. Apply in small steps (you)

Prefer targeted applies for the first run so each change can be verified:

1. Authentik: property mapping, then the apps whose redirect URIs changed (verify OIDC login).
2. Cloudflare tunnel ingress and Access apps.
3. Gatus module (creates the provider, secret and Vault entries).
4. Everything else.

Create the Semaphore task with `-target=<address>` arguments where the template allows, or run the
full apply once the plan is clean. After each step re-run the plan; the goal is "No changes".

## 7. Retire the old working directory (you)

After one clean "No changes" plan from Semaphore:

```bash
mv automation/infra-as-code/terraform/deployments/terraform.tfstate{,.migrated-$(date +%F)}
```

Keep the migrated file and the backup offline for at least one backup cycle, then securely delete
them. Do not run Terraform locally against the repo again: the backend path only exists in the
Semaphore pod (use `terraform init -backend=false` for local `validate`).

Optional: add a scheduled plan-only template for drift detection. Do not schedule apply templates.

## Troubleshooting

| Symptom in the Semaphore log | Cause / fix |
|---|---|
| `no space left on device` while installing providers | Providers must not land on the small work volume. `TF_DATA_DIR` (ConfigMap `semaphoreui-terraform-config`) points them at an emptyDir. |
| `403 ... Authentication error` (code 10000) on `cloudflare_dns_record` | The Cloudflare token lacks **Zone > DNS > Edit** on the zone in `cloudflare_zone_id` (account-level permissions alone are not enough). Fix the token, then update Vault and reload as below. |
| Plan wants to remove Cloudflare Access policies | Policies are dashboard-managed; the module ignores them (`ignore_changes = [policies]`). |
| `permission denied` (403) writing a secret under `infra/semaphoreui`, `infra/argocd`, `infra/openwebui`, `apps/forgejo`, `apps/n8n`, `apps/vaultwarden` | The fail-closed Vault guard. Patch the needed keys by hand with `vault kv patch`; do not remove the guard. |

After changing a value in `secret/infra/terraform`, reload it into Semaphore:

```bash
kubectl -n semaphoreui annotate externalsecret semaphoreui-terraform-env force-sync=$(date +%s) --overwrite
kubectl -n semaphoreui rollout restart deploy/semaphoreui
```

Verify a Cloudflare token without printing it (needs the zone ID):

```bash
printf 'Token: '; stty -echo; read -r CF; stty echo; echo
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $CF" \
  "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records?per_page=1"   # expect 200
unset CF
```

## Rollback

- **Semaphore side:** revert the PR; Flux removes the init container and mounts. The PVC with the
  state is kept unless you delete it.
- **State:** copy it back with `kubectl cp` from the pod to a local file and run Terraform locally
  with the same backend path replaced by a local one.
- **Vault:** `secret/infra/terraform` and the `terraform-semaphore` role are independent of
  application secrets; delete them with `vault kv metadata delete` / `vault delete` if needed.
- **Applied infrastructure changes:** revert through Terraform (git revert plus apply) or restore
  Vault secrets from KV versions (`vault kv rollback -version=N`).

## Follow-ups

- Make `vault-app-secret` preserve keys it does not manage (or split Terraform-owned values into
  their own paths) and then remove the six deny rules from the policy.
- Set a KV v2 `max_versions` on the `secret` mount so versions stop accumulating.
- One source of truth for service hostnames (issue #361).
- A scheduled plan-only template with notifications.
