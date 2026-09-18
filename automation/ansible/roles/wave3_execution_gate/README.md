# wave3_execution_gate

Optional read-only diagnostic gate retained from the 2026-09 catch-up cycle.

Run it when kubeadm configuration, drain behavior, Longhorn state, or platform prerequisites have
changed materially:

```text
playbook=playbooks/61-wave3-execution-gate.yml
limit=k8s-master01
```

The gate runs on the control plane and does not change kubeadm configuration, cordon/drain nodes,
update packages, restart services, or reboot.

It checks:

- `kubeadm upgrade plan` parsing;
- the centrally configured Calico and Longhorn baseline;
- Longhorn volume health;
- Flux readiness;
- server-side dry-run drain behavior for workers.

Important: a server-side drain dry-run does not persist the cordon, so it does not reproduce all of
Longhorn's live-cordon reconciliation behavior. For routine monthly maintenance, playbook 60 plus
the fail-closed worker canary is the normal path. Use this role as diagnostic evidence, not as a
mandatory recurring gate.
