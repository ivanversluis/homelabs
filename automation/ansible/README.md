# Wave -1 control-tower Ansible content

Ansible execution layer for the kubeadm/Arch Linux homelab lifecycle control tower:

```text
GitHub = desired automation content   (this directory)
Ansible = execution mechanism         (this directory)
SemaphoreUI = control tower / orchestration
Vault = short-lived SSH trust and secrets
Flux = Kubernetes desired state
```

This directory does **not** perform Kubernetes/Arch Linux/Longhorn/Calico/Cilium/kube-vip
upgrades. See [`../../docs/lifecycle/maintenance-plan.md`](../../docs/lifecycle/maintenance-plan.md)
for that future work.

## Layout

```text
inventories/homelab/       # explicit node addresses, never passwords/private keys
roles/
  control_tower_preflight/   read-only drift checks, run before every step
  vault_ssh_certificate/     configures Vault as the SSH client CA + signing role/policy
  ssh_automation_account/    creates the `ansible` account + certificate-only sshd trust
  control_tower_validation/  node-level positive checks
playbooks/
  00-control-tower-preflight.yml    read-only, admin route
  01-control-tower-smoke-test.yml   ping/raw connectivity, admin route
  05-control-tower-vault-ca.yml     configures Vault SSH CA (localhost -> Vault API only)
  10-control-tower-ssh-accounts.yml creates `ansible` account + CA trust, admin route
  90-control-tower-validation.yml   full validation, ansible-certificate route
```

## Two SSH routes

1. **Admin bootstrap route** (`control_tower_bootstrap: true`) — the existing interactive
   `admin`/`wheel` account, used only for the one-time run that creates the `ansible` account
   and installs the Vault CA trust anchor. Never uses `sshpass`.
2. **Ansible certificate route** (default) — a per-run ephemeral Ed25519 keypair signed by
   Vault for principal `ansible`, TTL ≤ 60 minutes. See
   `scripts/lifecycle/bootstrap-control-tower.sh` for how the keypair/certificate are
   generated, used, and destroyed.

## Running

```bash
cd automation/ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/00-control-tower-preflight.yml
```

Prefer driving these playbooks through `scripts/lifecycle/bootstrap-control-tower.sh`, which
wires up the correct route, ephemeral credentials, and validation for each stage.

## Non-negotiables

- Never store passwords, private keys, or Vault tokens in this repository.
- Never remove or weaken the `admin` break-glass account.
- Never disable global `PasswordAuthentication` — only the `ansible` account is
  certificate-only.
- Never widen the Semaphore→node SSH NetworkPolicy beyond the four explicit node `/32`s.
