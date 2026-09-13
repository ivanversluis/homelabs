---
mode: agent
description: Implement and validate the Wave -1 Ansible/Semaphore/Vault SSH control tower without performing platform upgrades.
---

# Wave -1 — Homelab lifecycle control tower

Work in the current `ivanversluis/homelabs` repository. Treat the latest `main` branch and the live cluster as the source of truth. This is an existing infra/automation task; do not ask which repository area to use.

## Mission

Build the lifecycle-management foundation for the kubeadm/Arch Linux Kubernetes homelab:

```text
GitHub = desired automation content
Ansible = execution mechanism
SemaphoreUI = control tower / orchestration
Vault = short-lived SSH trust and secrets
Flux = Kubernetes desired state
```

Do not perform Kubernetes, Arch Linux, Longhorn, Calico, Cilium, kube-vip, or application version upgrades as part of Wave -1.

## Current Wave status

```text
Wave -1a  repository tooling and validation             COMPLETE
Wave -1b  one-time pre-change backup                     COMPLETE
Wave -1c  activate SSH/Ansible/Semaphore control tower    COMPLETE
Wave -1d  validate control tower end-to-end               COMPLETE
Wave -1e  optional SSH host certificates later            NOT STARTED (pending)
```

A verified Wave -1b backup was completed on 2026-09-09:

```text
/var/lib/homelab-backups/pre-maintenance/20260909T144749Z
```

Validation completed successfully for etcd, PostgreSQL logical dumps, all selected Bound PVC archives, native Prometheus TSDB snapshot/archive, offline Vault PVC archive, and SHA-256 checksums. `vms/debian-bookworm-dv` was intentionally excluded.

Wave -1c live activation copied the complete backup directory to Synology and
`sha256sum -c SHA256SUMS` succeeded there, confirmed by the operator. The post-activation
Vault checkpoint backup (`post-wave-1c/20260910T183848Z`) has also been copied to Synology
and checksum-verified. See [`wave-minus1-handoff.md`](../../docs/lifecycle/wave-minus1-handoff.md)
for the full closure record. Wave -1e (host CA / Vault-signed host certificates) remains
not implemented; this does not block Wave 0.5 or Wave 1. See
[`maintenance-plan.md`](../../docs/lifecycle/maintenance-plan.md) for the Wave 0.5
read-only maintenance-readiness gate and the Wave 1-5 sequence.

## Known cluster state

```text
k8s-master01  172.16.20.200  control-plane  Kubernetes 1.35.1
k8s-worker01  172.16.20.201  worker         Kubernetes 1.35.2
k8s-worker02  172.16.20.202  worker         Kubernetes 1.35.2
k8s-worker03  172.16.20.203  worker         Kubernetes 1.35.2
```

All nodes run Arch Linux.

Current effective SSH baseline on all four nodes:

```text
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
TrustedUserCAKeys none
AuthenticationMethods any
```

`admin` is the existing human/break-glass account, UID 1000, member of `wheel`, with full interactive sudo.

Do not remove or weaken the `admin` recovery path during Wave -1. Do not disable global password authentication during Wave -1.

Vault currently runs standalone with file storage under `/vault/data`. It may currently be sealed. Never assume Vault is unsealed; detect its state before any Vault-dependent live operation.

SemaphoreUI currently uses the pinned Helm chart/image in `infra/semaphoreui/semaphoreui-helmrelease.yaml`. Inspect the current file and chart before changing values.

The current Semaphore NetworkPolicy still contains a historical SSH CIDR that must be replaced during Wave -1c implementation. Resolve the current repo state before editing rather than relying only on this prompt.

## First execution: repository-only implementation

On the first run of this prompt:

1. Inspect current `main` and ensure the working tree state is understood.
2. Read `.github/copilot-instructions.md`, `.github/agents/devsecops-engineer.agent.md`, `infra/semaphoreui/*`, `scripts/vault-post-deploy.sh`, `docs/ssh-agent-wsl-setup.md`, and relevant Flux/Kustomize wiring.
3. Use live cluster commands only for read-only discovery when needed.
4. Implement the repository code, manifests, Ansible content, scripts, tests, and documentation described below.
5. Do not execute bootstrap/control-tower activation against the nodes or Vault in this first repo-only pass.
6. Run all available static/render validation.
7. Review `git diff` for secret leakage and accidental live-version changes.
8. Commit and push the validated repository changes to `main` as requested by the repository owner. Never force-push. If `main` moved while working, update/rebase safely and rerun validation before pushing.
9. Report the resulting commit SHA and exact commands for the next live phase.

## Target repository structure

Use existing repository conventions, targeting approximately:

```text
automation/
└── ansible/
    ├── README.md
    ├── ansible.cfg
    ├── requirements.yml
    ├── inventories/homelab/
    │   ├── hosts.yml
    │   └── group_vars/
    │       ├── all.yml
    │       ├── control_plane.yml
    │       └── workers.yml
    ├── roles/
    │   ├── control_tower_preflight/
    │   ├── vault_ssh_certificate/
    │   ├── ssh_automation_account/
    │   └── control_tower_validation/
    └── playbooks/
        ├── 00-control-tower-preflight.yml
        ├── 01-control-tower-smoke-test.yml
        └── 90-control-tower-validation.yml

scripts/lifecycle/
├── bootstrap-control-tower.sh
├── validate-control-tower.sh
└── lib/common.sh

docs/lifecycle/
├── maintenance-plan.md
├── wave-minus1-control-tower.md
└── restore-runbook.md
```

Do not duplicate an existing repository abstraction when one already exists.

## Ansible inventory

Use explicit node addresses and never store passwords/private keys in inventory:

```yaml
all:
  children:
    control_plane:
      hosts:
        k8s-master01:
          ansible_host: 172.16.20.200
    workers:
      hosts:
        k8s-worker01:
          ansible_host: 172.16.20.201
        k8s-worker02:
          ansible_host: 172.16.20.202
        k8s-worker03:
          ansible_host: 172.16.20.203
```

## Bootstrap orchestration

Create an idempotent `scripts/lifecycle/bootstrap-control-tower.sh` intended to be launched from the owner's VS Code WSL shell.

Support:

```bash
./scripts/lifecycle/bootstrap-control-tower.sh preflight
./scripts/lifecycle/bootstrap-control-tower.sh vault-ca
./scripts/lifecycle/bootstrap-control-tower.sh nodes
./scripts/lifecycle/bootstrap-control-tower.sh semaphore
./scripts/lifecycle/bootstrap-control-tower.sh validate
./scripts/lifecycle/bootstrap-control-tower.sh all
```

and `--dry-run`, `--node <hostname>`, `--verbose`.

Initial node bootstrap must use the existing interactive `admin` SSH/sudo route. Never use `sshpass`.

When live node changes are approved, process one node at a time. Before changing SSH config on a node: back up changed files, write atomically, run `sshd -t`, reload rather than restart sshd, prove a second independent SSH session works, and restore previous files automatically if validation fails.

## Dedicated automation identity

Create:

```text
username: ansible
home: /home/ansible
shell: /bin/bash
password: locked/disabled
wheel membership: no
```

Provide `/etc/sudoers.d/90-ansible` containing:

```text
ansible ALL=(ALL) NOPASSWD: ALL
```

Validate with `visudo -cf`. Do not alter `admin` sudo configuration.

## Vault SSH client CA

Use HashiCorp Vault SSH secrets engine with signed OpenSSH user certificates at:

```text
ssh-client-signer/
```

Let Vault generate and retain the CA private key. Never export or commit the CA private key.

Create signing role `homelab-ansible` with:

```text
certificate type: user
allowed/default principal: ansible
default TTL: 30 minutes
maximum TTL: 60 minutes
```

Restrict certificate extensions. Do not permit agent forwarding, X11 forwarding, arbitrary TCP forwarding, or tunneling unless proven necessary. Create the minimum Vault policy required to issue/sign through this one role.

Never place Vault root tokens, unseal keys, CA private keys, passwords, or long-lived Vault tokens in Git, Semaphore variables, test output, generated logs, or CI artifacts.

## Semaphore -> Vault authentication

Do not bind Vault permissions to the namespace `default` ServiceAccount.

Inspect the exact ServiceAccount and Helm chart capabilities of the currently pinned Semaphore deployment. Prefer a dedicated ServiceAccount `semaphore-ansible`, bound to a Vault Kubernetes-auth role only in namespace `semaphoreui`. The Vault policy must permit only the required SSH signing/issue operation.

Before finalizing, inspect the live Semaphore pod/image and prove whether Python, OpenSSH client, `ssh-keygen`, Ansible, and required tooling are present. Do not invent chart values.

## Ephemeral SSH credential model

Do not store a permanent node SSH private key in Git.

Preferred runtime flow:

```text
Semaphore task
 -> create ephemeral Ed25519 keypair
 -> read Kubernetes ServiceAccount JWT
 -> authenticate to Vault Kubernetes auth
 -> obtain short-lived SSH user certificate for principal ansible
 -> run Ansible with id_ed25519 + id_ed25519-cert.pub
 -> destroy private key, certificate and Vault token on success/failure
```

Use Semaphore task metadata in certificate `key_id` when available. If the current Semaphore version cannot cleanly implement this model, stop and document the exact limitation plus the smallest secure alternative. Do not silently fall back to a permanent private key.

## Node SSH configuration

Install only the Vault public user CA, e.g. `/etc/ssh/trusted-user-ca-keys.pem`.

Use `/etc/ssh/sshd_config.d/60-homelab-automation.conf`, `TrustedUserCAKeys`, and an explicit `AuthorizedPrincipalsFile`, e.g. `/etc/ssh/auth_principals/ansible` containing `ansible`.

For the `ansible` account require public-key/certificate authentication and disable password authentication for that account.

Preserve globally during Wave -1:

```text
PermitRootLogin no
PasswordAuthentication yes
```

Do not add `StrictHostKeyChecking=no`. Use pinned current SSH host keys/known_hosts for server identity. Vault-signed host certificates belong to optional Wave -1e.

## Semaphore NetworkPolicy

Inspect `infra/semaphoreui/semaphoreui-netpol.yaml` and replace the historical/wrong node SSH CIDR with explicit `/32` access only to:

```text
172.16.20.200/32 TCP/22
172.16.20.201/32 TCP/22
172.16.20.202/32 TCP/22
172.16.20.203/32 TCP/22
```

Add Semaphore -> Vault connectivity limited to Vault on TCP/8200. Preserve required DNS, Kong/OIDC, Git/Ansible Galaxy, and same-namespace behavior. Do not introduce broad RFC1918 egress.

Because this manifest is Flux-managed, clearly identify any commit that will trigger live reconciliation. In the first repo-only pass, do not activate Wave -1c live behavior without explicit approval.

## Control-tower validation

Create `scripts/lifecycle/validate-control-tower.sh` and Ansible validation tasks.

Positive cases must prove:

```text
Vault SSH CA exists
Vault signing role exists
Semaphore Kubernetes auth to Vault succeeds
certificate TTL <= 60 minutes
certificate principal = ansible
signed certificate can SSH to all four nodes
ansible user exists on every node
ansible password is locked
sudo -n true succeeds as ansible
sshd configuration passes sshd -t
Semaphore can reach each node on TCP/22
Semaphore can reach Vault on TCP/8200
Ansible ping/raw succeeds on all nodes
admin break-glass account still exists
sshd remains enabled and active
```

Negative cases where safe:

```text
ansible password authentication cannot be used
unsigned arbitrary key cannot log in as ansible
wrong-principal Vault certificate cannot log in as ansible
root SSH remains disabled
Semaphore cannot SSH to arbitrary RFC1918 hosts outside the declared node /32s
```

Never print credentials/private keys/tokens.

## Future maintenance foundation

Do not implement component upgrades yet. Document future Ansible lifecycle properties:

```yaml
serial: 1
any_errors_fatal: true
max_fail_percentage: 0
```

Execution model:

```text
preflight -> cordon -> drain -> host maintenance -> reboot if required -> wait SSH -> Node Ready -> validate Calico -> validate Longhorn -> uncordon -> application/observability health gate -> next node
```

Rules: never `pacman -Syu` all nodes concurrently; never use `kubectl drain --disable-eviction` by default; honor PDBs; inspect Longhorn node-drain policy; abort on degraded Longhorn volumes or unhealthy Calico; remember there is one control-plane node; Kubernetes minor kubeadm upgrades require control-plane-first even though normal OS maintenance begins with a worker canary.

## Validation before pushing

Run all available relevant checks:

```text
bash -n
shellcheck
yamllint
ansible-lint
ansible-playbook --syntax-check
kustomize build / kubectl kustomize for affected manifests
existing repository validation scripts
git diff --check
```

Search changed files for credential/token/private-key leakage. If a validator is unavailable, report that explicitly. Do not install global tools without approval.

## Documentation requirements

Explain SSH private key vs SSH certificate, client/user CA vs host CA, Vault signing role, SSH certificate principal and TTL, why Semaphore uses Kubernetes auth to Vault, why permanent Semaphore node keys are avoided, why `admin` stays break-glass, why host certificates are deferred, bootstrap chicken/egg, and why in-cluster Vault/Semaphore cannot be the only recovery path for the cluster hosting them.

Update any Semaphore documentation that has drifted from actual pinned versions.

## Live Wave -1c gate

Do not execute live Wave -1c changes until the user explicitly confirms:

1. Wave -1b backup copied to Synology;
2. `sha256sum -c SHA256SUMS` passed on the Synology copy;
3. explicit instruction equivalent to `Wave -1c live activation approved`.

At that point re-run read-only preflight, detect Vault sealed state, obtain unseal material interactively without persistence if needed, bootstrap one node at a time, validate after every node, stop on any failed SSH recovery test, configure Semaphore/Vault only after node trust is proven, run complete positive/negative validation, and create a post-Wave -1c Vault checkpoint backup because the SSH CA private key will then exist in Vault storage.

## Completion output

Return:

1. files created/modified;
2. architecture summary;
3. security decisions/trade-offs;
4. static/render validation results;
5. live read-only observations;
6. whether any pushed Flux manifest would reconcile live changes;
7. commit SHA pushed to `main`;
8. exact next command/prompt for the user;
9. explicit remaining live-activation gates.
