# Semaphore task 89: plan review

Reviewed the operator-supplied log on 2026-10-22. Source: `main` at `d762ef9`.
The Access preservation PR was not merged into that commit. The locally prepared fixes were
also not part of that run. No apply was reported in the supplied log.

**Decision: do not apply.** The run ended with a Cloudflare DNS GET authentication error.
`9 add, 30 change, 0 destroy` describes an incomplete plan, not an approved change set.
In-place changes can remove access controls and rewrite secrets without destroying resources.

| Visible changes | Assessment / prerequisite |
|---|---|
| Homepage and Longhorn Access policies become null | Blocker: removes all visible policy attachments. Apply the PR fix to the code being planned and rerun. Preserve existing application IDs/AUDs. |
| One shared Cloudflare tunnel config update | Blocker pending a private, field-by-field comparison of all ingress rules and origin options. Terraform rebuilds managed routes. The text plan hides this diff. |
| Global Authentik email scope sets `email_verified` true | Security decision, not execution migration. Verify actual upstream email-ownership verification before approving a claim for all users. |
| OAuth redirect URIs for 11 existing providers; launch URLs for 10 existing apps | Verify old/new hostnames and callback paths privately against each application's live configuration and DNS/certificate readiness. New domain alone does not prove all callbacks should change. No existing client-secret change is visible. |
| Whole-secret updates: Gatus, Headlamp, Homepage, Longhorn, Open WebUI | Blocker until managed and foreign key sets are reconciled. `disable_read=true` prevents drift detection. Open WebUI is explicitly denied by the Semaphore Vault policy; a plan can succeed for it but its write will fail at apply. Other unguarded paths may still lose keys. |
| New random secrets: Gatus and Longhorn cookies, Homepage auth | Check whether each value already exists live. Adopt/preserve an existing value rather than unintentionally rotating it. Even cookie rotation invalidates sessions. |
| New Gatus Authentik provider/app/group/entitlement/client ID/grant patch | Check for pre-existing live objects absent from state before creating duplicates. Verify Python and forwarded environment inputs for the grant PATCH. This patch previously read a nonexistent local tfvars file. |
| Gatus DNS record refresh returns 403 | Check `cloudflare_api_token`, `cloudflare_zone_id`, token zone scope/permissions, expiry and any source-IP restrictions. Successful account-level Tunnel/Access reads do not prove access to the selected DNS zone. |

## Why the six Vault denies are insufficient

They prevent writes to six mixed-owner paths, including the visible Open WebUI write, if the
Semaphore task really uses that policy. They do not prevent preceding Authentik/Cloudflare changes,
or writes to unguarded paths. Terraform apply is not a cross-provider transaction.

Do not remove those denies. The next Vault refactor should give Terraform-owned credentials their
own secret paths, with a staged ESO migration that verifies new values before switching consumers.
Alternatively use a genuinely field-level KV patch implementation with version/CAS controls. A
read/merge/full-write workaround or `ignore_absent_fields` alone does not make concurrent writes
safe. This PR does not change secret ownership or ESO consumer paths without live key inventory.

## Next plan

1. Run plan-only from the updated PR branch/commit, not unchanged `main`. Keep the original state.
   Do not run two Terraform workflows against the same backend or tunnel at once.
2. Repair the Cloudflare DNS input and verify a *completed* refreshed ExternalSecret before restarting
   Semaphore. The helper in the migration runbook waits for this.
3. Confirm the policy removals are gone. Preserve state addresses; do not recreate/import duplicates
   to hide state mismatches. Policy ownership changes need the documented `state mv`.
4. Compare sensitive callback/tunnel values locally; share a redacted description of the differences.
   Never publish a raw JSON/binary plan, Vault data or the private domain.
5. Reconcile every planned secret write and existing live random value. Keep apply disabled until
   all blockers have a concrete resolution; then review a fresh full plan.

Passing unit/mock checks validates code behavior, not these live migration prerequisites.
