# control_tower_preflight

Read-only checks that must pass before any Wave -1c control-tower step runs. Makes no
changes to node state.

Asserts:
- `PermitRootLogin no` (global baseline preserved)
- `PasswordAuthentication yes` (global baseline preserved — the ansible-only restriction
  is applied later via an sshd `Match User` block, never globally)
- the `admin` break-glass account exists and is still a member of `wheel`
- `sshd` is enabled and active
- reports free disk space on `/`

Run via `automation/ansible/playbooks/00-control-tower-preflight.yml`, or
`scripts/lifecycle/bootstrap-control-tower.sh preflight`.
