# Wave -1 control tower — architecture & security decisions

This document explains the Wave -1c/-1d SSH/Ansible/Semaphore/Vault control tower: what it
is, why each piece exists, and the gates that must be satisfied before it goes live.

```text
GitHub = desired automation content   (this repo)
Ansible = execution mechanism         (automation/ansible/)
SemaphoreUI = control tower / orchestration
Vault = short-lived SSH trust and secrets
Flux = Kubernetes desired state
```

## SSH private key vs SSH certificate

A traditional SSH **key pair** grants access forever (or until manually revoked from every
`authorized_keys` file it was copied into). An SSH **certificate** is a short-lived,
cryptographically signed statement from a trusted authority saying "this public key may log
in as principal X until time T". The node never needs to store or update anything when a
certificate expires — it just stops being valid. This is why the control tower issues
certificates instead of managing permanent keys.

## Client (user) CA vs host CA

- **Client/user CA** (implemented in Wave -1c): signs the *client's* key so a node can verify
  "this connecting user is really who they claim to be" via `TrustedUserCAKeys`. This is what
  lets Semaphore prove its ephemeral key is legitimate without the node needing a copy of
  every key Semaphore ever generates.
- **Host CA** (deferred to Wave -1e): would sign each *node's* host key so operators don't
  have to manually accept/pin `known_hosts` fingerprints. Wave -1c intentionally uses pinned
  current host keys instead — this is lower-risk to add later and not required for the
  automation account to work safely today.

## Vault signing role `homelab-ansible`

A Vault SSH secrets engine "role" is a named policy template for what certificates it is
allowed to issue: which principals, which extensions, and what TTL bounds. `homelab-ansible`
is scoped to:

- `allowed_users=ansible` — certificates can only ever be valid for the `ansible` principal
- `default_extensions=permit-pty` only — no agent forwarding, X11 forwarding, or TCP/tunnel
  forwarding are permitted unless a concrete future need is proven
- `ttl=30m`, `max_ttl=60m` — short enough that a leaked certificate is only dangerous for a
  bounded window

## Certificate principal and TTL

The **principal** on a signed certificate is the value checked against
`AuthorizedPrincipalsFile` on the node — it is what actually authorizes the login, not the
account name in the certificate's key ID. Restricting `allowed_users`/principal to `ansible`
means even if Vault's signing role were somehow invoked with a different intended user, the
node would refuse the certificate for any principal other than `ansible`. The 30–60 minute
TTL bounds the blast radius of certificate theft in a way a permanent key never can.

## Why Semaphore uses Kubernetes auth to Vault (not a static token)

Semaphore already runs in-cluster with a projected ServiceAccount token. Vault's Kubernetes
auth method lets Semaphore exchange that token for a Vault token scoped to exactly one policy
(`homelab-ansible-sign`), bound to exactly one namespace (`semaphoreui`) and one
ServiceAccount (`semaphore-ansible`) — never `default`. There is no static Vault credential
to leak, rotate, or accidentally commit; the trust chain is Kubernetes' own identity, which
Kubernetes itself already secures.

## Why Semaphore never gets a permanent node SSH key

A permanent key baked into a Semaphore task, ExternalSecret, or container image is a
standing credential that must be manually rotated and manually revoked from every node if it
leaks — exactly the failure mode certificates are designed to avoid. The ephemeral flow
(generate keypair → Vault Kubernetes-auth → sign → run Ansible → destroy) means there is
never a point in time where a long-lived Semaphore SSH credential exists at rest.

## Why `admin` stays break-glass

`admin` is the only account that can still authenticate with a password and is a member of
`wheel`. If Vault, Semaphore, or the entire control-tower certificate chain is ever
unavailable (Vault sealed, Semaphore down, cluster unreachable), `admin` is the only way back
into a node. Wave -1 never disables it, never removes its `wheel` membership, and never
disables global `PasswordAuthentication` — doing so would make the cluster's own recovery
path dependent on the cluster being healthy, which is a circular failure mode.

## Why host certificates are deferred to Wave -1e

Host certificates remove the manual "TOFU" (trust-on-first-use) step of accepting a node's
SSH fingerprint. They are a genuine improvement but are strictly optional for the automation
account to function safely today — Wave -1c already pins current host keys. Bundling host CA
issuance into the same wave as the client CA would combine two independent blast radii
(client trust and host trust) into one change; keeping them separate makes each easier to
validate and roll back independently.

**Current status:** Wave -1e has not been implemented. No `ssh-host-signer` Vault mount
exists and `known_hosts` on the control tower still contains only pinned plain
`ssh-ed25519` keys (no `@cert-authority` lines). This is not required for Wave 0.5 or Wave 1
to proceed and remains an optional future improvement.

## Bootstrap chicken/egg problem

Before the `ansible` account and Vault CA trust exist on a node, the *only* way to create
them is over the existing `admin`/`wheel` SSH route — there is nothing else to authenticate
with yet. This is why `roles/ssh_automation_account` and
`playbooks/10-control-tower-ssh-accounts.yml` explicitly use
`control_tower_bootstrap: true` (the admin route) for that one-time run, and every
certificate-route playbook afterward defaults to the `ansible` account instead.

## Why in-cluster Vault/Semaphore cannot be the sole recovery path

Vault and Semaphore both run as workloads *on* the cluster they help manage. If the cluster
control plane, Vault's PVC, or the Semaphore pod itself is the thing that's broken, neither
can be used to fix it — the automation would need to reach through the failure to repair the
failure. This is precisely why:

- `admin`/`wheel` remains a fully independent, always-available SSH route to every node,
  unrelated to Vault or Semaphore being healthy;
- the Wave -1b pre-maintenance backup (etcd, Vault filesystem, PostgreSQL dumps, PVC
  archives) exists and is verified offsite *before* any live Wave -1c change, precisely so a
  human with direct node/SSH access and the backup archive can restore the cluster even if
  Vault or Semaphore themselves are the casualty.

## Future maintenance foundation

Component upgrades (Kubernetes, Arch Linux, Longhorn, Calico/Cilium, kube-vip, applications)
are explicitly out of scope for Wave -1. See
[`maintenance-plan.md`](./maintenance-plan.md) for the documented (not yet implemented)
future lifecycle model this control tower is being built to eventually run.

## Live activation gate

Live Wave -1c changes require, in order:
1. Wave -1b backup copied to Synology and `sha256sum -c SHA256SUMS` passing there (see
   [`wave-minus1-handoff.md`](./wave-minus1-handoff.md));
2. explicit operator instruction: `Wave -1c live activation approved`.

Only then does `scripts/lifecycle/bootstrap-control-tower.sh` get run against the live
cluster, one stage and one node at a time, validating after every step.
