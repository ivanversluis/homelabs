# Wave 3: coordinated Arch Linux + Kubernetes

Status: **LIVE PREFLIGHT COMPLETE — KUBEADM CONFIG REPAIRED — EXECUTION GATE RERUN PENDING**.

Wave 3 is the first lifecycle stage where host package state, reboot behavior, kubeadm ordering,
CNI/storage health and disruption policy interact. Preparation and execution are therefore
intentionally separated.

## Live preflight evidence — Semaphore task 45

`playbooks/60-wave3-preflight.yml` completed successfully across all four nodes through the
Semaphore -> Vault -> ephemeral SSH certificate -> Ansible control-tower path. No package,
Kubernetes, drain, reboot, or service mutation was performed.

Observed baseline:

- `k8s-master01`: kernel `6.18.13-arch1-1`, kubeadm/kubelet/kubectl `1.35.1`, containerd `2.2.1`, runc `1.4.0`.
- `k8s-worker01/02/03`: kernel `6.19.8-arch1-1`, kubeadm/kubelet/kubectl `1.35.2`, containerd `2.2.2`, runc `1.4.1`.
- system Python is not merely broken: the `python` package and `/usr/bin/python3` are absent on all four nodes. The standalone control-tower Python remains the safe automation interpreter until a full Arch synchronization restores system Python.
- the existing pacman sync database reports a large pending Arch update set including glibc 2.44, kernel 7.2.4, systemd 261.x, containerd 2.3.5, runc 1.5.1 and Kubernetes 1.36.4. Because `checkupdates` is unavailable, this evidence may be stale and is not by itself approval to mutate.
- Kubernetes reports four Ready nodes. Running control-plane and kube-proxy images remain `v1.35.0`; kubelet packages are newer (`1.35.1`/`1.35.2`).
- `kubeadm upgrade plan` sees cluster version `1.35.0` and, with current kubeadm `1.35.1`, offers the latest patch in that minor (`v1.35.8`).
- Calico `v3.32.1` is healthy and all TigeraStatus objects are Available, not Progressing or Degraded.
- Longhorn manager `v1.12.1` is present; all listed V1 volumes are healthy. Node drain policy remains `block-if-contains-last-replica` and several instance-manager PDBs have `disruptionsAllowed=0`.
- Flux Kustomizations/HelmReleases reported Ready.

## Execution gate evidence — Semaphore task 47

`playbooks/61-wave3-execution-gate.yml` correctly blocked mutation and printed the exact live
`ClusterConfiguration`. The malformed shape was proven rather than inferred:

```yaml
apiServer:
  extraArgs:
    - name: oidc-issuer-url
      value: <existing live value>
    - name: oidc-client-id
      value: <existing live value>
    - name: oidc-username-claim
      value: preferred_username
    - name: oidc-groups-claim
      value: groups
apiServer: {}
```

The empty second top-level `apiServer: {}` was line 11 in the live ConfigMap. kubeadm reported:

```text
strict decoding error: yaml: unmarshal errors:
  line 11: key "apiServer" already set in map
```

The first `apiServer` block was the valid one because it contains the active Authentik OIDC
configuration. The repair therefore had to preserve that complete block and remove only the empty duplicate.

The execution-gate reporting regex was also simplified after Task 47 exposed a Python-regex
FutureWarning from the earlier POSIX character class; this was a reporting-only issue and did
not affect the kubeadm blocker detection.

## Targeted kubeadm ConfigMap repair — Semaphore task 48

The repair playbook was executed successfully:

```text
playbook=playbooks/62-wave3-kubeadm-config-repair.yml
limit=k8s-master01
```

Task 48 proved the repair was exactly one line:

```diff
-apiServer: {}
```

The populated Authentik OIDC `apiServer.extraArgs` block was preserved. Before mutation the
playbook validated the exact expected malformed shape, created a protected backup, materialized
current and corrected ClusterConfiguration files, proved that exactly one line would be removed,
and validated the corrected file with kubeadm.

The corrected configuration was then uploaded through kubeadm. Post-repair validation proved:

- backup created at `/var/lib/homelab-backups/wave3-kubeadm-config-repair/kubeadm-config-before-20260911T143410Z.yaml`;
- kube-apiserver static manifest checksum remained `4ca70108c6014942ea154df25bace7e73be5f35d7f0803968702e6448a8aa3fb` before and after the ConfigMap repair;
- no API-server manifest rewrite or restart was triggered by this repair;
- `kubeadm upgrade plan` now parses the ClusterConfiguration without the prior strict-decoding error;
- cluster version remains `1.35.0`;
- kubeadm remains `v1.35.1`;
- current 1.35-series target remains `v1.35.8` until kubeadm itself is deliberately advanced for the 1.36 minor-upgrade path.

Task 48 completed with `failed=0` and the explicit result:

```text
WAVE 3 KUBEADM CONFIG REPAIR: SUCCESS
```

The duplicate configuration blocker is therefore resolved. The next required step is to rerun the
read-only execution gate so Calico, Longhorn, Flux and all worker drain simulations can be evaluated
without being short-circuited by the kubeadm parsing error:

```text
playbook=playbooks/61-wave3-execution-gate.yml
limit=k8s-master01
```

Only a clean execution gate may unlock preparation of the actual Wave 3 mutation playbooks.

## Target-selection rule

Kubernetes `v1.36.4` is the current Arch-repository candidate seen by the preflight and remains
the intended minor target, but it is not yet approved for execution. The current kubeadm binary
is still 1.35.x, so its plan correctly resolves only the 1.35 patch line. The supported kubeadm
minor-upgrade sequence requires upgrading the kubeadm binary first, re-running `kubeadm upgrade
plan`, then applying the control-plane upgrade before worker kubelets move to the new minor.

Do not jump to Kubernetes 1.37. Current Wave 1/2 add-on baselines were selected for the 1.36
maintenance path.

## Arch/Kubernetes sequencing model

Arch is rolling release and does not support arbitrary partial system upgrades. Kubernetes,
however, requires kubeadm/control-plane-first ordering for a minor upgrade and kubelets must not
be advanced ahead of the API server. Wave 3 must therefore keep these concerns explicit rather
than running one blind `pacman -Syu` loop.

Planned stages after the execution gate is clean:

1. refresh/reconfirm package targets without creating a partial-upgrade state;
2. perform worker-canary Arch host maintenance while holding Kubernetes packages at the current minor;
3. validate/reboot that worker and repeat workers one at a time;
4. perform equivalent Arch host maintenance on the single control-plane node with explicit downtime/recovery gate;
5. upgrade kubeadm on the control plane to the approved 1.36 patch, re-run `kubeadm upgrade plan`, then `kubeadm upgrade apply`;
6. upgrade/restart the control-plane kubelet/kubectl and validate API server, etcd, Calico, Longhorn and Flux;
7. upgrade workers to the same Kubernetes patch one at a time using kubeadm node semantics, kubelet restart and full post-node health gates;
8. rerun `50-maintenance-readiness.yml` against `k8s_homelab` before Wave 4.

The exact mutating upgrade playbooks remain intentionally uncommitted until the execution/drain
gate is clean.

## Safety properties

Every mutating playbook must use:

```yaml
serial: 1
any_errors_fatal: true
max_fail_percentage: 0
```

Never bypass PDBs by default, never use `kubectl drain --disable-eviction` as a routine option,
never run `pacman -Syu` concurrently, and never use `pacman -Sy <package>`.

The single control-plane node has no HA fallback. Before mutation re-confirm etcd recovery,
Longhorn backups/volume health, Vault/Semaphore recovery and the independent admin break-glass
route.
