# wave3_kubeadm_config_repair

Narrow repair for the malformed `kube-system/kubeadm-config` `ClusterConfiguration` found by Wave 3 Task #47.

Observed live shape:

```yaml
apiServer:
  extraArgs:
    - name: oidc-issuer-url
      value: ...
    - name: oidc-client-id
      value: ...
    - name: oidc-username-claim
      value: preferred_username
    - name: oidc-groups-claim
      value: groups
apiServer: {}
```

The role removes only the exact empty duplicate `apiServer: {}` line. It preserves the existing OIDC values from the live ConfigMap; those values are not stored in this role.

Safety controls:

- asserts exactly one populated `apiServer:` block and one empty duplicate exist;
- asserts all four expected OIDC argument names exist exactly once;
- asserts the current stored Kubernetes version is `v1.35.0`;
- backs up the full ConfigMap under `/var/lib/homelab-backups/wave3-kubeadm-config-repair/`;
- builds a corrected temporary file by deleting only `^apiServer: {}$`;
- proves exactly one line was removed;
- shows the diff before mutation;
- runs `kubeadm config validate` before upload;
- uploads with `kubeadm init phase upload-config kubeadm --config ...`;
- proves the kube-apiserver static Pod manifest checksum did not change;
- reruns `kubeadm upgrade plan` and fails if any strict-decoding error remains.

Run from Semaphore only after reviewing the Task #47 evidence:

```text
playbook=playbooks/62-wave3-kubeadm-config-repair.yml
limit=k8s-master01
```

After success, rerun:

```text
playbook=playbooks/61-wave3-execution-gate.yml
limit=k8s-master01
```

This role does not perform a Kubernetes upgrade, Arch package synchronization, drain, reboot, service restart, or static Pod manifest edit.
