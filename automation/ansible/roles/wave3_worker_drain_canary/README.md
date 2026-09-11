# wave3_worker_drain_canary

Prepared but disabled one-worker live-drain canary for Wave 3.

This role exists because Task 52 proved all Longhorn volumes, engines, and replicas already use
v1.12.1 while the active engine processes are still hosted by v1.11 instance-manager pods. A
server-side drain dry-run cannot empty those old instance managers because workload pods are not
actually evicted and their attached volumes never move.

## Activation gate

The role is committed with:

```yaml
wave3_canary_approved: false
```

It will stop immediately until the operator explicitly approves the disruptive canary and a
follow-up Git commit changes that value to `true`.

The only allowed target is `k8s-worker02`. Task 50 showed no Semaphore or Vault workload on that
worker, and the role re-checks that condition immediately before cordoning.

## What an approved run does

1. Re-validates node, Longhorn policy, manager/default-engine image, volume health, and absence of
   old v1.11 engine/volume/replica image references.
2. Refuses to proceed if Semaphore or Vault pods are running on the target.
3. Records Longhorn instance-manager/PDB and workload placement evidence.
4. Persists a real cordon on `k8s-worker02`.
5. Runs a real `kubectl drain` using normal Kubernetes eviction/PDB semantics.
6. Never uses `--disable-eviction`, `--force`, pod deletion, or a weaker Longhorn drain policy.
7. Waits for Longhorn volumes to return healthy and records post-drain evidence.
8. Always uncordons the node in an Ansible `always` block.

This canary **does evict and reschedule application pods**. It is intentionally separate from the
read-only Wave 3 gates and must not be activated implicitly.

Normal execution, only after the explicit activation commit:

```text
playbook=playbooks/65-wave3-worker-drain-canary.yml
limit=k8s-master01
```

If Semaphore itself is interrupted after the cordon and before cleanup, use the independent
break-glass path and run:

```bash
kubectl uncordon k8s-worker02
```

Do not proceed to Arch or kubeadm mutation solely because this canary succeeds; record the live
evidence first and then construct the node-maintenance playbooks around that proven behavior.
