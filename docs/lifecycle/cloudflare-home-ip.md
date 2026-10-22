# Dedicated dynamic home IP group for Cloudflare Access

Prepared as an inactive n8n workflow: `automation/n8n/cloudflare-home-ip/workflow.json`.
No Cloudflare policy/group was created or attached; no workflow was activated. Existing PIP and
email policies remain untouched. This is a separate staged change after the Terraform plan blockers.

## Ownership and access behavior

Use a new Access **rule group** named `homelab-dynamic-home-ip`, containing exactly one public IPv4
`/32` Include selector, with empty Exclude and Require lists. This is an Access group, not a WAF
ruleset. Do not reuse or edit the existing shared PIP group/policy.

Selected behavior (operator decision, 2026-10-22): **keep IP bypass; applications handle login**.
Create a dedicated policy named `Bypass - dynamic home IP`, with action **Bypass** and an Include
selector for rule group `homelab-dynamic-home-ip`. Keep its Exclude and Require lists empty. The
policy skips Cloudflare Access authentication for the matching home IPv4; each application's own
OIDC/login and authorization remain responsible for access. Do not add a Cloudflare identity or
MFA requirement to this home-IP bypass.

An API body template is provided at
`automation/n8n/cloudflare-home-ip/bypass-policy.template.json`. Substitute the new group's ID
privately before using it; the placeholder is intentionally not a valid live object ID. Policy
creation and attachment are separate from the n8n updater, which only changes group membership.

Preserve existing non-home policies and recovery access. Stage the dedicated bypass on a test
hostname first: verify that home traffic reaches the application login without an Access login,
and that signed-out users still cannot reach protected application content. Test outside-home
traffic against the existing non-home policy. The visible Homepage plan had only a bypass, so
do not assume it already has an email fallback. Keep PIP untouched during preparation and testing;
replacing a PIP attachment is a separate per-application migration, not a side effect of this draft.
Preserve the complete ordered policy list if Terraform adopts attachments.

Ownership:

- n8n is the sole writer of the dedicated group's IP membership.
- Initially create the new group and policy through the dashboard; record their IDs privately.
  Audit that the new group is referenced only by the dedicated bypass and intended apps. Attach
  first to the test hostname, then migrate production attachments after the checks above.
- Dashboard-owned app attachments stay protected by the empty-ID Terraform path. If Terraform later
  owns policies/attachments, explicitly wire the complete ordered policy list and migrate state as
  documented. Terraform must not also reconcile the group's changing IP Include list.
- Keep IPv6 out of this first version. A v4-only rule will not admit a client connecting via IPv6;
  validate real client traffic and design a separate bounded IPv6 rule before expanding scope.

## Import and dry run

1. Create the dedicated one-IP group with the current *home WAN* IPv4 `/32` and the exact name above.
2. Import `workflow.json` into n8n. It is inactive, `dry_run: true`, with blank IDs and no credentials.
3. In Config, set private account/group IDs. Keep the exact group name and boolean dry-run setting.
4. For **Read dedicated group**, **Update dedicated group**, and **Read back**, select an n8n HTTP
   Header Auth credential: header `Authorization`, value `Bearer <token>`. Keep tokens in n8n's
   encrypted credential store, never in Code nodes, JSON, logs or Git. Use a separate Cloudflare token
   with Access Apps and Policies permission on the required account, distinct from Terraform's token.
   Dry run can use a read-capable token; enabling updates requires Edit.
5. Run manually from the intended home egress. The workflow compares `api.ipify.org` and
   `ipv4.icanhazip.com`, reads only the configured group, and refuses any unexpected group name,
   ID, selector, non-global IPv4 or disagreement. An unchanged IP performs no write. Inspect the
   Prepare result privately, and verify that this matches the source IP Access sees from home.

An n8n instance behind another VPN/proxy/NAT will measure that egress, not necessarily the home WAN.
This must be established before activation. Two agreeing services cannot prove that vantage point.

The workflow's selectors are bounded, but the Cloudflare API token permission can be account-wide:
this is not an API-enforced per-group credential. A compromised n8n/token could have broader access.
For a stronger boundary, put a narrow authenticated update service in front that fixes the group ID
and validates the single IP payload; do not give n8n a general Access editing credential.

## Activation and failure behavior

After the selected bypass behavior, egress and test-hostname checks pass, set `dry_run: false` and
activate the five-minute schedule. Enforce one writer and no overlapping executions, including
manual runs. Cloudflare group updates are whole-object PUTs without a CAS control in this workflow;
concurrent dashboard/automation writes can be lost. Never edit the group from another workflow.

On a changed address, the only write is a PUT of the exact one-IP payload to the configured Access
group, followed by GET read-back verification. Errors stop the execution; there is no broad CIDR,
Everyone fallback, bypass creation or automatic rollback. If PUT succeeds but read-back fails, treat
state as uncertain and inspect before retrying. Keep execution saving disabled as shipped; configure
an operator-visible failure alert separately without leaking IPs or tokens. No alert destination is
configured by this draft.

Stopping n8n leaves the last IP allowed. That can become stale or be reassigned; this design has no
lease/expiry. Monitor updater failures and promptly remove stale membership through the recovery
procedure. Do not add an always-allow fallback to recover access.

## Validation and remaining checks

`node --test automation/n8n/cloudflare-home-ip/logic.test.js` tests validation, no-change/dry-run
behavior, the one-IP payload and read-back checks. Regenerate the JSON with
`python3 automation/n8n/cloudflare-home-ip/build-workflow.py` after editing `logic.js`.
The JSON is prepared for import; its node/credential configuration and live API responses still
need manual verification in the installed n8n version before activation.

Official references:

- https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/groups/methods/update/
- https://developers.cloudflare.com/reference-architecture/design-guides/designing-ztna-access-policies/
- https://developers.cloudflare.com/cloudflare-one/access-controls/policies/
