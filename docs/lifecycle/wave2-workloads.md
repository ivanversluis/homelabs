# Wave 2: workload repository move

## Goal

Move workload source files into a single architectural parent without changing live Kubernetes ownership:

```text
apps/ -> workloads/apps/
vms/  -> workloads/vms/
clusters/k8s-homelab/apps/ -> clusters/k8s-homelab/workloads/
```

This is intentionally a **path-only migration**. Existing Flux `Kustomization` names and Argo CD application identities must not change.

## Non-negotiable invariants

- Flux Kustomization names remain: `homepage`, `homebox`, `forgejo`, `vaultwarden`, `n8n`, `linkding`, `termix`, `vms`.
- Their dependencies, `prune`, `postBuild`, sourceRef, namespaces, and managed manifests remain unchanged.
- `vms` continues to depend on `kubevirt` and `cdi`.
- Firewall Manager remains owned by the same Argo CD ApplicationSet and application names.
- No workload Namespace, PVC, CRD, StorageClass, or operator resource changes ownership.
- Existing Vault paths remain unchanged.

## Copilot pre-merge validation

Run these checks against the branch before merge and report every command/result. Do not merge on any unexplained difference.

### 1. Repository path audit

Confirm the old workload roots are absent and the new roots exist:

```bash
test ! -e apps
test ! -e vms
test -d workloads/apps
test -d workloads/vms
test -d clusters/k8s-homelab/workloads
```

Search for stale repository-path references. Classify matches carefully: Vault keys such as `apps/<component>` are data contracts and must not be changed just because the repository moved.

```bash
git grep -nE '(^|[[:space:]`"/])apps/' -- ':!workloads/apps/**'
git grep -nE '(^|[[:space:]`"/])vms/' -- ':!workloads/vms/**'
```

Any operational reference to the old repository locations must be fixed. Historical text or Vault secret keys must be explicitly justified.

### 2. Build/render validation

Render the cluster root and every moved workload path:

```bash
kustomize build clusters/k8s-homelab >/tmp/wave2-cluster.yaml

for p in \
  workloads/apps/homepage \
  workloads/apps/homebox \
  workloads/apps/forgejo \
  workloads/apps/vaultwarden \
  workloads/apps/n8n \
  workloads/apps/linkding \
  workloads/apps/termix \
  workloads/vms; do
  kustomize build "$p" >/dev/null
done
```

Validate the Firewall Manager overlays as well:

```bash
for env in dev staging prod; do
  kustomize build "workloads/apps/firewall-manager/overlays/$env" >/dev/null
done
```

### 3. Flux definition invariant

Compare `main` against the branch for each workload Kustomization. The only semantic change allowed is `spec.path` plus comments/file location.

Expected paths:

```text
homepage    ./workloads/apps/homepage
homebox     ./workloads/apps/homebox
forgejo     ./workloads/apps/forgejo
vaultwarden ./workloads/apps/vaultwarden
n8n         ./workloads/apps/n8n
linkding    ./workloads/apps/linkding
termix      ./workloads/apps/termix
vms         ./workloads/vms
```

Reject the PR if any Kustomization `metadata.name`, namespace, `dependsOn`, `prune`, `force`, `postBuild`, health check, or sourceRef changed unexpectedly.

### 4. Live ownership/inventory preflight

Because Wave 1 exposed a prune/inventory incident, inspect live ownership before merge:

```bash
flux get kustomizations -n flux-system

for ks in homepage homebox forgejo vaultwarden n8n linkding termix vms; do
  echo "===== $ks ====="
  flux tree ks "$ks" -n flux-system
  kubectl get kustomization "$ks" -n flux-system -o jsonpath='{.spec.path}{"\n"}'
done
```

Also inspect the root inventory and ensure it does not own workload Namespaces/PVCs that are expected to belong to dedicated workload Kustomizations:

```bash
flux tree ks flux-system -n flux-system
```

If a live resource appears under both root and a workload Kustomization, stop. Do not merge until ownership is understood and a staged transfer plan exists.

### 5. Flux dry-run/diff

Use Flux diff against the branch if available in the local validation environment. The expected result is patching Kustomization `spec.path` values, not deleting/recreating workload resources.

Pay special attention to `Namespace`, `PersistentVolumeClaim`, `VirtualMachine`, `DataVolume`, and StatefulSet resources. Any proposed deletion is a merge blocker.

### 6. Argo CD validation

Confirm the ApplicationSet source path changes only from:

```text
apps/firewall-manager/overlays/{{.env}}
```

to:

```text
workloads/apps/firewall-manager/overlays/{{.env}}
```

Application names, target namespaces, sync policy, and image-updater annotations must remain unchanged.

### 7. Post-merge observation gate

Immediately after merge:

```bash
flux get kustomizations -n flux-system
kubectl get pods -A
kubectl get pvc -A
kubectl get vm,vmi,dv -n vms
kubectl get applications,applicationsets -n argocd
```

Then inspect recent Flux events for deletion/prune activity:

```bash
flux events --for Kustomization/flux-system -n flux-system
flux events --for Kustomization/vms -n flux-system
```

There must be no unexpected Namespace/PVC/VM/DataVolume deletion. Confirm all application Kustomizations are Ready and Argo CD applications remain Synced/Healthy.

## Merge gate

Do not approve or merge if any automated reviewer reports P1/P2 ownership, prune, inventory, persistence, or stale operational-path issues. Resolve the finding, rerun validation, and trigger a fresh review on the final commit.
