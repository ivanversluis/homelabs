# Wave 3 pinned Kubernetes control-plane upgrade

This role upgrades the kubeadm-managed control plane from Kubernetes `v1.35.0` to exactly `v1.36.4` without draining or rebooting `k8s-master01` and without running `pacman`.

Safety gates:

- explicit `wave3_cp_upgrade_approved=true`;
- exact reviewed target `v1.36.4`;
- fresh recovery marker from playbook 66, maximum age two hours;
- checksum-valid local etcd snapshot;
- Longhorn SystemBackup `Ready` with `volumeBackupPolicy: always`;
- all nodes Ready, Longhorn volumes healthy, Calico v3.32.1 and Longhorn v1.12.1;
- kubeadm ClusterConfiguration still contains the four required OIDC arguments exactly once;
- exact upstream kubeadm v1.36.4 binary is downloaded from `dl.k8s.io` and checked against its published SHA-256;
- the target kubeadm binary must produce a clean `upgrade plan` before mutation;
- `/etc/kubernetes` is archived immediately before `kubeadm upgrade apply`;
- target images are pre-pulled before apply;
- after apply the API server, controller-manager and scheduler must all run v1.36.4 and OIDC arguments must remain present in both kubeadm ConfigMap and kube-apiserver manifest;
- nodes, Calico, Longhorn and active Flux resources must be healthy.

`kubeadm upgrade apply` also manages kubeadm addons such as kube-proxy/CoreDNS according to the normal kubeadm upgrade workflow. The host kubelet and Arch packages remain unchanged until the later node-maintenance stages.

Run only after playbook 66 succeeds:

```text
playbook=playbooks/67-wave3-control-plane-upgrade.yml
limit=k8s-master01
```

The expected intermediate state after success is API server/control-plane v1.36.4 with kubelets still on their current v1.35.x versions. This is intentional and within Kubernetes version-skew policy. Worker02 is the first worker host/kubelet upgrade canary after this gate.
