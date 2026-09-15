# Wave 3 node-upgrade execution

This runbook continues Wave 3 after the kubeadm-managed control plane has reached Kubernetes
`v1.36.4` through `67-wave3-control-plane-upgrade.yml`.

The intended starting state is:

- Kubernetes API server/control-plane: `v1.36.4`;
- kube-proxy: `v1.36.4`;
- worker kubelets: `v1.35.x`;
- control-plane kubelet/package binaries: `v1.35.x`;
- Calico: `v3.32.1` healthy;
- Longhorn manager: `v1.12.1` healthy;
- Longhorn backup target `default`: configured and available.

## Safety model

The node-upgrade role is fail closed.

- Kubernetes package repository candidates must resolve to `1.36.4-*` before mutation.
- Repository probing uses an isolated pacman database and does not refresh the system sync database.
- The real host update is a full `pacman -Syu`; no `pacman -Sy <package>` partial upgrade is used.
- Workers are cordoned and drained with normal eviction semantics only.
- No `--disable-eviction`, forced pod deletion, or Longhorn policy weakening is used.
- Longhorn volumes must be healthy before host package mutation.
- A failed worker run intentionally leaves the worker cordoned; do not manually uncordon until the
  failure is understood and the node/platform health gates pass.
- Every worker is upgraded in a separate Semaphore task so it receives a fresh Vault SSH certificate.
- The single control-plane host is upgraded only after every worker reports kubelet `v1.36.4`.
- Control-plane host maintenance requires a fresh Wave 3 recovery checkpoint no older than two hours.

The role writes a local marker on the node:

```text
/var/lib/homelab-maintenance/wave3-node-upgrade.env
```

Successful completion changes the marker state to `COMPLETE`. An interrupted or failed run leaves
`STATE=IN_PROGRESS`, which is deliberate evidence for recovery/resume.

## 1. Upgrade worker02 canary

Run:

```text
playbook=playbooks/68-wave3-worker-upgrade-canary.yml
limit=k8s-worker02
```

The playbook will:

1. verify the API server is exactly `v1.36.4`;
2. verify all nodes, Calico, Longhorn, backup target and volumes are healthy;
3. verify the configured Arch repositories still offer `1.36.4-*` for kubeadm/kubelet/kubectl;
4. cordon worker02;
5. perform staged normal drain attempts using the Longhorn/PDB behavior proven earlier in Wave 3;
6. require all Longhorn volumes healthy;
7. run a full `pacman -Syu`;
8. verify installed Kubernetes packages are exactly `1.36.4-*`;
9. run `kubeadm upgrade node`;
10. reboot worker02;
11. require sshd, containerd and kubelet active and kubelet `v1.36.4`;
12. require Kubernetes, Calico and Longhorn health;
13. uncordon worker02;
14. require final node, Longhorn and Flux health.

Expected final evidence:

```text
WAVE 3 NODE UPGRADE: k8s-worker02 READY AT v1.36.4
```

Do not continue if this task fails.

## 2. Upgrade worker01

Run playbook 69 for exactly one worker:

```text
playbook=playbooks/69-wave3-worker-upgrade.yml
limit=k8s-worker01
```

Playbook 69 refuses to run against multiple workers in one Semaphore task. It also requires the
worker02 canary to remain Ready, schedulable, and at kubelet `v1.36.4` before mutation.

Expected evidence:

```text
WAVE 3 NODE UPGRADE: k8s-worker01 READY AT v1.36.4
```

## 3. Upgrade worker03

Start a new Semaphore task so a new Vault SSH certificate is issued:

```text
playbook=playbooks/69-wave3-worker-upgrade.yml
limit=k8s-worker03
```

Expected evidence:

```text
WAVE 3 NODE UPGRADE: k8s-worker03 READY AT v1.36.4
```

At this point all three worker kubelets must report `v1.36.4`.

## 4. Create a fresh control-plane recovery checkpoint

Immediately before host maintenance on the single control-plane node, run:

```text
playbook=playbooks/66-wave3-recovery-checkpoint.yml
limit=k8s-master01
```

Require:

```text
WAVE 3 RECOVERY CHECKPOINT: READY
```

Do not reuse an expired checkpoint. Playbook 70 enforces the same two-hour freshness gate as the
control-plane Kubernetes upgrade.

## 5. Upgrade the control-plane host

Run:

```text
playbook=playbooks/70-wave3-control-plane-host-upgrade.yml
limit=k8s-master01
```

This does **not** execute `kubeadm upgrade apply` again. The control plane is already v1.36.4.
It upgrades the Arch host and node-side Kubernetes packages, then reboots the single control-plane
host.

Before mutation it requires:

- every worker Ready at kubelet `v1.36.4`;
- API server `v1.36.4`;
- healthy Calico and Longhorn;
- available Longhorn backup target;
- a fresh etcd snapshot and Ready Longhorn SystemBackup.

After reboot it requires:

- kubeadm and kubelet `v1.36.4`;
- API server still `v1.36.4`;
- Authentik OIDC arguments preserved in both kubeadm ConfigMap and kube-apiserver manifest;
- all nodes Ready;
- Longhorn, Calico and Flux healthy.

Expected evidence:

```text
WAVE 3 NODE UPGRADE: k8s-master01 READY AT v1.36.4
```

## 6. Run the final Wave 3 completion gate

Run:

```text
playbook=playbooks/71-wave3-completion-gate.yml
limit=k8s_homelab
```

The first play validates each host sequentially. Only after all four host checks pass does the
second play validate the complete Kubernetes/platform state from the control plane.

Expected final verdict:

```text
WAVE 3 COMPLETE
```

Then run the general maintenance-readiness gate again:

```text
playbook=playbooks/50-maintenance-readiness.yml
limit=k8s_homelab
```

## Failure handling

If a worker upgrade fails after cordon, assume the node should remain cordoned. Inspect:

```bash
kubectl get nodes -o wide
kubectl get pods -A --field-selector spec.nodeName=<worker> -o wide
kubectl -n longhorn-system get volumes.longhorn.io
kubectl get tigerastatus
sudo cat /var/lib/homelab-maintenance/wave3-node-upgrade.env
```

Do not use `kubectl uncordon` simply to make the task green. Fix or understand the failed gate,
then rerun the same playbook against the same node; the role is designed so already-completed
package work can be revalidated and the maintenance sequence can continue.

If control-plane host maintenance fails after reboot, use the independent `admin` break-glass SSH
route and the fresh recovery checkpoint evidence created immediately before playbook 70.
