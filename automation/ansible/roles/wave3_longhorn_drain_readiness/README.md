# wave3_longhorn_drain_readiness

Read-only Wave 3 follow-up after the generic execution gate showed all three worker drain
simulations timing out only on Longhorn instance-manager PodDisruptionBudgets.

Run through Semaphore:

```text
playbook=playbooks/63-wave3-longhorn-drain-readiness.yml
limit=k8s-master01
```

The role does **not** cordon, drain, evict, patch, restart, or reboot anything. It records:

- Kubernetes Ready state for all workers;
- Longhorn `node-drain-policy`;
- `detach-manually-attached-volumes-when-cordoned`;
- `disable-scheduling-on-cordoned-node`;
- Longhorn node scheduling/eviction state;
- volume state, robustness, replica count and data locality;
- replica placement and health fields;
- instance-manager placement/state/image;
- Longhorn PDB health/disruption allowance;
- Longhorn pods running on each worker.

## Why this exists

`kubectl drain --dry-run=server` simulates the Kubernetes API requests, including the node
cordon, but it does not leave the node persistently unschedulable. Longhorn has behavior that
is specifically triggered by a cordoned node (for example, disabling replica scheduling on
cordoned nodes, and optionally detaching manually attached volumes). Therefore the Task 50
PDB result is valuable evidence but is not sufficient by itself to prove how Longhorn will
reconcile its instance-manager PDBs after a real cordon.

The next step must be a separately reviewed, reversible live-cordon probe against **one worker
only**. Such a probe must:

1. establish all preconditions before mutation;
2. cordon only the selected worker;
3. wait/observe Longhorn controller, instance-manager and PDB reconciliation;
4. run a drain dry-run while the node is actually cordoned;
5. perform no eviction of workload pods;
6. uncordon in an Ansible `always` path even if validation fails;
7. stop for operator review before a real drain.

Do not work around Longhorn PDBs with `--disable-eviction`, forced pod deletion, or by weakening
the node-drain policy.
