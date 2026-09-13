# wave3_preflight

Read-only preparation for Wave 3: coordinated Arch Linux + kubeadm/Kubernetes maintenance.

The role deliberately uses `ansible.builtin.raw` for node inspection so it does not depend on
`/usr/bin/python3`; repairing the broken system Python is one of the Wave 3 goals. It does not
run `pacman -Syu`, `kubeadm upgrade apply/node`, cordon, drain, restart services, reboot, or
change cluster state.

Run through the existing Semaphore control-tower runner:

```text
playbook=playbooks/60-wave3-preflight.yml
limit=k8s_homelab
```

The authoritative preflight requires all four nodes. It checks:

- pacman database consistency and relevant installed/update-candidate package versions;
- system Python path/package/dynamic-linker diagnostics;
- cgroup v2 and swap prerequisites for Kubernetes 1.36;
- kernel, kubeadm, kubelet, kubectl, containerd, runc, and critical service state;
- running control-plane/kube-proxy images and kubeadm ClusterConfiguration;
- read-only `kubeadm upgrade plan` output;
- Calico v3.32.1/TigeraStatus baseline;
- Longhorn v1.12.1, volume/node state, node-drain policy and PDB constraints;
- Flux reconciliation state.

`wave3_target_patch_candidate` is documentation for the current planning window only. The
actual target must be confirmed from the live Arch repository plus upstream support matrices
immediately before an operator approves a mutating Wave 3 playbook.

Any repository candidate beyond Kubernetes 1.36 is rejected by this preparation gate because
Calico v3.32 and Longhorn v1.12.1 are currently tested through Kubernetes 1.36, not 1.37.
