# control_tower_validation

Node-level positive checks proving the control tower is working, run over the
Vault-issued certificate route (not the admin bootstrap route).

Asserts per node:
- `ansible.builtin.ping` and `raw` connectivity both succeed
- `ansible` automation account exists with a **locked** password
- `sudo -n true` succeeds passwordlessly as `ansible`
- `sshd -t` passes and the service is active/enabled
- the `admin` break-glass account still exists
- `PermitRootLogin no` is still in effect

Cluster-level checks that need `kubectl`/`curl` rather than SSH (Vault CA/role existence,
Semaphore→Vault Kubernetes-auth success, certificate TTL/principal, NetworkPolicy
connectivity, and the negative security tests) live in
`scripts/lifecycle/validate-control-tower.sh`, which also invokes this role's playbook
(`automation/ansible/playbooks/90-control-tower-validation.yml`) for the node-level half.
