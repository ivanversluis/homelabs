# wave3_preflight

Read-only preparation for recurring coordinated Arch Linux + kubeadm/Kubernetes maintenance.

The legacy `wave3_` name is retained for compatibility with existing Semaphore templates. The
reviewed Kubernetes, Calico and Longhorn targets are sourced from
`inventories/homelab/group_vars/all.yml`.

The role deliberately uses `ansible.builtin.raw` for node inspection so preflight does not depend
on the node's system Python. It does not run `pacman -Syu`, `kubeadm upgrade apply/node`, cordon,
drain, restart services, reboot, or change cluster state.

Run:

```text
playbook=playbooks/60-wave3-preflight.yml
limit=k8s_homelab
```

The authoritative preflight requires all cluster nodes. It checks:

- pacman database consistency and relevant installed/update-candidate package versions;
- system Python path/package/dynamic-linker diagnostics;
- cgroup v2 and swap prerequisites;
- kernel, kubeadm, kubelet, kubectl, containerd, runc, and critical service state;
- running control-plane/kube-proxy images and kubeadm ClusterConfiguration;
- read-only `kubeadm upgrade plan` output;
- the centrally configured Calico/TigeraStatus baseline;
- the centrally configured Longhorn manager, volume/node state, node-drain policy and PDB state;
- Flux reconciliation state.

The preflight reports repository candidates, but the mutating node-upgrade role is the final
fail-closed check: it probes the live repositories in an isolated pacman database and requires the
kubeadm/kubelet/kubectl candidate to match the reviewed package prefix.

Do not encode a permanent maximum Kubernetes minor here. A future minor is allowed only after the
central lifecycle target and compatibility baseline are changed in a reviewed PR.
