# Compute layout migration

## Scope and ownership

| Previous repository path | New repository path |
|---|---|
| `clusters/k8s-homelab/` | `compute/eliteboxes/` |
| `clusters/synology/` | `compute/synology/` |
| No existing entrypoint | `compute/pi4/` documentation placeholder |

This is a repository path move. The root Flux Kustomization remains `flux-system` in namespace `flux-system`; its inventory and child reconciliation identities remain unchanged. Only its `spec.path` changes to `./compute/eliteboxes`. Child component source paths still point to `platform/`, `infra/`, `services/`, and `workloads/`.

No Kubernetes resources transfer owners. Do not uninstall/rebootstrap Flux, delete its namespace, or recreate Kustomizations for this migration. Pi4 and Synology are outside the EliteBox root and have no new active deployment configuration.

## Live Flux cutover

Run these commands from a trusted shell against the existing EliteBox cluster. They are operator actions; opening this PR does not run them.

### Before merging

Confirm the Kubernetes context and capture the current root path and inventory:

```bash
kubectl config current-context
kubectl -n flux-system get kustomization flux-system -o yaml > /tmp/flux-system-before-compute.yaml
flux get kustomizations -A
kubectl get pvc -A
flux suspend kustomization flux-system -n flux-system
kubectl -n flux-system get kustomization flux-system -o jsonpath='{.spec.suspend}{"\n"}'
```

Verify suspension reports `true`, then merge the PR after repository checks/review pass. Only the root is suspended; existing child reconciliation and running workloads continue.

### After merging

Fetch the merged `main` revision while the root is suspended:

```bash
flux reconcile source git flux-system -n flux-system
kubectl -n flux-system get gitrepository flux-system -o jsonpath='{.status.artifact.revision}{"\n"}'
```

Confirm the artifact revision contains the merged change. Then update the existing root object, resume, and reconcile:

```bash
kubectl -n flux-system patch kustomization.kustomize.toolkit.fluxcd.io flux-system \
  --type=merge --patch '{"spec":{"path":"./compute/eliteboxes"}}'
flux resume kustomization flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system --with-source
kubectl -n flux-system wait kustomization/flux-system --for=condition=Ready --timeout=5m
```

Verify the committed `compute/eliteboxes/flux-system/gotk-sync.yaml` and the live object both use `./compute/eliteboxes`:

```bash
kubectl -n flux-system get kustomization flux-system -o jsonpath='{.spec.path}{"\n"}'
flux get kustomizations -A
flux tree kustomization flux-system -n flux-system
kubectl get pvc -A
kubectl get nodes
```

Compare the root inventory IDs with the saved YAML and confirm child owners, PVCs, nodes, and readiness remain stable. If the PR was already merged without suspension, suspend the root and perform the same after-merge sequence; a missing old directory should be corrected by updating the root path, not by deleting resources.

### Rollback

Suspend the root again, revert the refactor on `main` so the old directory exists, reconcile the Git source and verify the reverted revision, then patch the same root object's path back to `./clusters/k8s-homelab`. Resume and reconcile the root and verify inventory/readiness. Changing only the live path cannot roll back a repository revision that no longer contains the old directory.

## Argo CD

The moved ApplicationSet definition is `compute/eliteboxes/argo-cd/applicationset-fm-envs.yaml`. Flux still applies that same ApplicationSet through the root. Its names, destinations, automated sync policy, and source are unchanged:

- Repository: `https://github.com/ivanversluis/homelabs.git`.
- Revision: `main`.
- Source: `workloads/apps/firewall-manager/overlays/{{.env}}`.

No update is required for the repository-managed Firewall Manager Applications or the Argo CD HelmRelease path `./infra/argocd`. If an additional live Application or ApplicationSet configured outside this repository points at `clusters/...`, update its source path or generator directory to the corresponding `compute/...` path before syncing. Review the live Application/ApplicationSet YAML for those additional references; do not grant Argo CD ownership of the Flux root.

## Semaphore and repository tooling

No current Semaphore repository, inventory, task, or schedule path changes. The Ansible configuration still uses `automation/ansible/inventories/homelab/hosts.yml`, and the operational runner remains `scripts/lifecycle/semaphore-control-tower-run.sh`. Existing jobs still target `k8s_homelab` and the four EliteBox nodes.

The Kustomize CI workflow now watches `compute/**`; its render helper targets `compute/eliteboxes`. The mutable-image scanner and Flux/Kubernetes Renovate file patterns scan `compute/`. Agent instructions and operating documentation use the new paths. These do not require changes in running controllers.

## Future Pi4 and Synology onboarding

Onboarding is later work. `compute/pi4` is a placeholder; `compute/synology` retains the existing Container Manager Compose definition.

For each future Kubernetes cluster:

1. Choose the OS/distribution, topology, storage, backup, network boundaries, and device-specific workloads. For Synology, establish whether Kubernetes runs in a VM or on another supported host; this refactor does not propose reimaging DSM.
2. Commit that environment's own Kubernetes root and selected shared components, with environment-specific overlays/secrets where required. Bootstrap Flux using `--path=compute/pi4` or `--path=compute/synology` only after those directories contain a valid Kubernetes entrypoint. Give each cluster independent credentials and context. Add every newly active root to `scripts/validate-kustomizations.sh` and adapt the generated Flux-controller exclusion in `scripts/validate-mutable-images.py` deliberately.
3. Keep native Synology DSM/Compose services under a separately designed deployment/maintenance mechanism. Kubernetes Flux does not directly deploy Docker Compose or patch DSM.
4. Extend Ansible inventory and host-key trust deliberately. The current runner pins `inventories/homelab/known_hosts` and its host-key preflight enumerates the four existing node targets, so a new inventory/group alone is insufficient. Add explicit environment selection and target validation before creating new Semaphore jobs.
5. Review Vault SSH signer authorization and the existing `infra/semaphoreui/semaphoreui-netpol.yaml` SSH destination allowlist. Add only the required new host addresses and OS-specific maintenance permissions. Do not broaden existing schedules to all hosts.
6. Define separate templates/schedules for Pi4 and Synology, suitable for their OS and runtime. Run read-only preflight, recovery checks, monitoring/notification tests, then a manual maintenance run before scheduling. Reimaging also requires refreshing pinned host keys.

Retain reusable automation under `automation/` and component definitions under their existing responsibility areas. `compute/<environment>/` holds environment-specific desired state and deployment wiring.
