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
exactly these six paths**. An apply that tries to update them fails with HTTP 403 instead of deleting keys.
A successful plan does NOT prove these writes will succeed: Terraform can change other resources
before hitting a denied write, and does not automatically roll those changes back. Do not remove the deny rules before the module preserves foreign keys.

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
unset CF
```

Check the token before using it (replace `<ACCOUNT_ID>`): 
`curl -s -H "Authorization: Bearer $TOKEN" https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/tokens/verify`

### 1.5 Let ESO read the inputs

The ESO role (`external-secrets`) gets read access through a list of per-path policies, so it needs
one for `secret/infra/terraform`. Without it the ExternalSecret reports `SecretSyncedError` with
`403 permission denied`. Reuse `vrun` from step 1.3:

```bash
vrun policy write external-secrets-terraform-inputs - \
  < automation/infra-as-code/terraform/bootstrap/external-secrets-terraform-inputs.hcl

# Append to the current policy list (a plain write would replace it).
POLS=$(vrun read -format=json auth/kubernetes/role/external-secrets < /dev/null | python3 -c '
import json, sys
p = json.load(sys.stdin)["data"]["token_policies"]
if "external-secrets-terraform-inputs" not in p:
    p.append("external-secrets-terraform-inputs")
print(",".join(p))')
echo "$POLS"   # review: all existing policies must still be listed

vrun write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets-operator \
  bound_service_account_namespaces=external-secrets-system \
  policies="$POLS" ttl=24h < /dev/null
```

Then force a sync and check:

```bash
./automation/infra-as-code/terraform/bootstrap/refresh-semaphore-env.sh
unset VT
```

Vault's note that the Kubernetes role has no audience configured is informational and can be ignored.

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
./automation/infra-as-code/terraform/bootstrap/refresh-semaphore-env.sh # waits for a NEW successful sync before restart
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

Task 89 review and remaining blockers are recorded in
[terraform-task-89-review.md](terraform-task-89-review.md). The dynamic home IP design is in
[cloudflare-home-ip.md](cloudflare-home-ip.md). Neither is permission to apply the partial plan.

Run the template and **stop at the confirmation prompt**. The task log must show Terraform
1.15.9, `Initializing the backend` with the local backend and `Refreshing state...` (not
"will be created" for everything). If Terraform says the state is newer than the binary, step 4.5
is not in effect.

A migration of the execution environment is not permission to apply existing drift. Review the
fresh plan against the transferred state and live configuration; the older WSL plan is not an
approval baseline. Keep apply disabled until every change is understood.

- **State:** stop if existing resources are planned for creation, destruction or replacement.
  Check the backend path, state lineage/serial and resource addresses before proceeding.
- **Cloudflare Access (Longhorn/Homepage):** empty `cf_access_policy_ids` means dashboard ownership.
  Existing attachments must stay intact. Stop on policy removals or Access application replacement.
  Nonempty IDs mean Terraform owns the complete list, including removals and precedence.
- **Tunnel ingress:** this is one shared config document for ALL published apps. Managed hostname
  rules are rebuilt, including `origin_request`; unmanaged rules are retained. Compare every route,
  origin, order, TLS option and Access JWT setting. `prevent_destroy` does not protect against a
  harmful in-place update. Pause dashboard/other-state writes between plan and apply.
- **Authentik:** review redirect URIs, grants, scope mappings, groups and entitlements. Verify the
  `email_verified` mapping is appropriate for your identity verification process before applying it.
- **Vault:** whole-secret writes can delete foreign keys, including outside the six guarded paths.
  Inventory key NAMES for every planned write (also `infra/gatus`, `apps/homepage`, `infra/longhorn`
  and `infra/vault`); retain a protected KV version backup. Do not paste values into logs or reviews.
  A write to a guarded path is a blocker, even if the plan succeeds. Keep the deny rules.
- **Random/OIDC secrets:** a resource planned for creation may replace an existing live credential
  that is absent from state. Reconcile state/inputs first. Do not accept cookie/client secret
  rotation as routine migration drift: it can invalidate sessions or break consumers.

### 5a. Adopt the existing Gatus objects (one-time)

Gatus was set up by hand, so its Authentik objects and the DNS record are live but not (correctly)
in the state. `deployments/gatus_imports.tf` adopts them with config-driven `import` blocks: the
Authentik group, OAuth provider and application, and the `gatus` CNAME. Vault secret, Vault policy and
the tunnel rule are already in state; the Authentik entitlement does not exist yet and is created.

1. The state still holds a DNS record ID from before the domain/zone change (it returns 404). Remove
   that stale entry once, in the Semaphore pod, before the first plan:

   ```bash
   kubectl -n semaphoreui exec deploy/semaphoreui -c semaphore -- sh -c '
     export TF_DATA_DIR=/tmp/tfd; mkdir -p $TF_DATA_DIR
     cd /tmp/semaphore/project_1/repository_1_template_2/automation/infra-as-code/terraform/deployments
     /opt/terraform-bin/terraform init -input=false -reconfigure >/dev/null
     /opt/terraform-bin/terraform state rm module.gatus.cloudflare_dns_record.gatus_cname'
   ```

   (Run a Semaphore task once first so the repository is cloned at the current commit.) Take a
   copy of the state file before editing it.
2. Run the plan. Expect `4 to import` and no destroy/replace for Gatus. The imported provider shows small
   diffs (new-tab flag, refresh threshold, `entitlements` scope); the authorization flow is pinned to the
   live explicit-consent flow in `gatus/main.tf`.
3. After the first successful apply, delete `gatus_imports.tf`.

Share the redacted text plan for review. Do not share `terraform show -json` or a saved binary plan:
those can contain plaintext secrets even when the text output hides them. Include the exact Git
commit and Terraform version, action counts, affected addresses and non-secret attribute changes.

### Cloudflare policy ownership changes

The dashboard resource retains the existing address `cloudflare_zero_trust_access_application.app[0]`.
The Terraform-owned resource is `cloudflare_zero_trust_access_application.app_managed[0]`. Both have
`prevent_destroy`: changing ownership without moving state must fail rather than recreate the app.
All current deployment callers omit policy IDs, so this fix requires no state moves for them.

To deliberately adopt an existing application into Terraform policy management:

1. Record ALL currently attached policy IDs in their current precedence order in private inputs.
   A partial list removes every omitted policy. Back up state and pause concurrent Terraform runs.
2. Configure the nonempty `cf_access_policy_ids` list on the composition caller. This root currently
   does not expose that list as a `TF_VAR`; edit the appropriate building module/private input wiring.
3. In the Semaphore backend environment, move the existing binding (example for Homepage):

   ```bash
   terraform state mv \
     'module.homepage.module.oidc.module.cloudflare.cloudflare_zero_trust_access_application.app[0]' \
     'module.homepage.module.oidc.module.cloudflare.cloudflare_zero_trust_access_application.app_managed[0]'
   ```

4. Run a fresh plan. The application ID and AUD must remain the same, with no create/delete/replace.
   First establish the same policy attachments, then review subsequent additions/removals/reordering.

If policy IDs were already nonempty before upgrading this module, move that application's old
`app[0]` binding to `app_managed[0]` before applying too. To return to dashboard management, clear
the list and reverse the state move. Do not use `state rm` or disable `prevent_destroy` to bypass
an ownership-transition error. Empty IDs preserve dashboard ownership; they do not mean “remove all”.

### Authentik grant-types provisioning in Semaphore

The grant-types workaround now reads `TF_VAR_authentik_url` and `TF_VAR_authentik_token` from
Semaphore's forwarded environment instead of trying to parse a nonexistent `terraform.tfvars`.
It requires `python3`, sends an authenticated PATCH without logging credentials or response data,
and refuses redirects. Local operators must export those same environment variables before an
apply that creates/replaces a grant-types provisioner. Existing resources are not forced to rerun
by this code fix; a previously failed provisioner must be reviewed/retried deliberately.

## 6. Apply only after the fresh plan is reviewed (you)

Do not apply while any item above remains unexplained. `-target` is a recovery tool, not a safety
boundary: it includes dependencies and may still write secrets or update a shared tunnel document.
If a staged change is needed, define and review its full dependency scope first.

Apply only the reviewed saved plan in the same controlled backend environment. Store that plan
securely and discard it if code, inputs, state or live configuration changes. Keep auto-approve
and scheduled applies disabled. After any apply failure, stop and make a fresh plan: successful
operations are not automatically rolled back. Verify application login, tunnel routing, ESO sync
and credentials after each approved stage, then run a full plan again.

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
| `403 ... Authentication error` (code 10000) on `cloudflare_dns_record` | The Cloudflare token lacks **Zone > DNS > Edit** on the zone in `cloudflare_zone_id` (account-level permissions alone are not enough). Check the API token and its permissions on the selected zone, then patch `cloudflare_api_token` in Vault and reload as below. This is not an Authentik OIDC client secret. |
| Plan wants to remove Cloudflare Access policies | Stop. Empty policy IDs preserve dashboard attachments; nonempty IDs authoritatively manage all attachments. Check ownership and state before applying. |
| `permission denied` (403) writing a secret under `infra/semaphoreui`, `infra/argocd`, `infra/openwebui`, `apps/forgejo`, `apps/n8n`, `apps/vaultwarden` | The fail-closed Vault guard. Patch the needed keys by hand with `vault kv patch`; do not remove the guard. |

After changing a value in `secret/infra/terraform`, reload it into Semaphore:

```bash
./automation/infra-as-code/terraform/bootstrap/refresh-semaphore-env.sh
```

The helper requires Bash, `kubectl` and `jq`. It waits for changed `refreshTime` AND
`syncedResourceVersion`, `Ready=True` and a nonempty target token before restarting. An already-true
Ready condition alone is insufficient. On timeout/API failure it exits without restarting; inspect
ESO status/events and fix the source, then retry. Do not run with shell tracing enabled.

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
