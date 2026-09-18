# wave3_control_plane_upgrade

Pinned, reviewed Kubernetes control-plane upgrade for the recurring maintenance workflow.

The legacy role name is retained for Semaphore compatibility. Source and target Kubernetes
versions plus the expected Calico/Longhorn baseline are configured centrally in
`inventories/homelab/group_vars/all.yml`.

Safety gates:

- explicit `wave3_cp_upgrade_approved=true`;
- current API server must equal the reviewed current or target version;
- fresh recovery marker from playbook 66, maximum age two hours;
- checksum-valid local etcd snapshot;
- Longhorn SystemBackup `Ready` with `volumeBackupPolicy: always`;
- all nodes Ready and Longhorn volumes healthy;
- current Calico and Longhorn versions must match the central lifecycle baseline;
- kubeadm ClusterConfiguration must still contain the required OIDC arguments exactly once;
- the exact upstream target kubeadm binary is downloaded from `dl.k8s.io` and verified against
  its published SHA-256;
- the target kubeadm binary must produce a clean `upgrade plan` before mutation;
- `/etc/kubernetes` is archived immediately before `kubeadm upgrade apply`;
- target images are pre-pulled before apply;
- after apply, API/control-plane components must be at the configured target and OIDC arguments
  must remain present;
- nodes, Calico, Longhorn and active Flux resources must be healthy.

The role does not run `pacman`, drain a node, reboot the host, or upgrade the host kubelet.
Host package maintenance is handled later by playbook 70.

Run only after playbook 66 succeeds:

```text
playbook=playbooks/67-wave3-control-plane-upgrade.yml
limit=k8s-master01
```

For a minor upgrade, temporary API-server/kubelet skew is intentional: control plane first, then
the configured worker canary and the remaining workers one at a time.
