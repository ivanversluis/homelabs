# wave3_execution_gate

Read-only gate between Wave 3 preparation and any live mutation.

Run from Semaphore:

```text
playbook=playbooks/61-wave3-execution-gate.yml
limit=k8s-master01
```

The gate runs on the control plane because it only needs cluster API access. It does not
change kubeadm configuration, cordon/drain nodes, update packages, restart services, or reboot.

It blocks if:

- `kubeadm upgrade plan` reports malformed ClusterConfiguration data, including duplicate YAML keys;
- the Calico v3.32.1 or Longhorn v1.12.1 baseline is not intact;
- any Longhorn volume is not healthy;
- any Flux Kustomization/HelmRelease is not Ready;
- a server-side dry-run of `kubectl drain` fails for any worker.

The current live preflight showed kubeadm warning about a duplicate `apiServer` key in the
`kubeadm-config` ConfigMap. Therefore the expected first run of this gate is BLOCKED and should
print the numbered live ClusterConfiguration needed to prepare a precise repair. Do not bypass
that condition.
