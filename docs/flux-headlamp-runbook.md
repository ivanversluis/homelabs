# Flux + Headlamp Runbook (Junior DevOps)

This guide covers:
- Recovering Flux after a broken/pruned `flux-system`
- Bootstrapping Flux from GitHub
- Validating what Flux deployed
- Setting up and validating Headlamp access
- Optional: enabling interactive terminal from Headlamp

## 1. Prerequisites

- `kubectl` installed and pointing to the right cluster
- `flux` CLI installed
- GitHub repo exists: `https://github.com/ivanversluis/homelabs`
- Branch: `main`
- Flux path in repo: `clusters/k8s-homelab`

Quick checks:

```bash
kubectl config current-context
flux --version
kubectl get ns
```

## 2. Recovery when `flux-system` is stuck Terminating

If namespace hangs in `Terminating`, first try uninstall:

```bash
flux uninstall --namespace flux-system --silent
```

If still stuck, inspect finalizers:

```bash
kubectl get ns flux-system -o jsonpath="{.spec.finalizers}{'\n'}"
kubectl get ns flux-system -o jsonpath="{.status.conditions}{'\n'}"
```

Force-remove namespace finalizers only if needed:

```bash
ns=$(kubectl get namespace flux-system -o json)
echo "$ns" | jq '.spec.finalizers=[]' | kubectl replace --raw "/api/v1/namespaces/flux-system/finalize" -f -
```

Wait for namespace deletion:

```bash
kubectl get ns flux-system -w
```

## 3. Bootstrap Flux from GitHub

From repo root, confirm this file includes `flux-system`:
- `clusters/k8s-homelab/kustomization.yaml`

Expected:

```yaml
resources:
  - flux-system
  - infra
  # - apps
```

Bootstrap:

```bash
flux bootstrap github \
  --owner=ivanversluis \
  --repository=homelabs \
  --branch=main \
  --path=clusters/k8s-homelab \
  --personal \
  --private=false
```

### If bootstrap fails with 403 on deploy keys

Example error:
- `GET /repos/.../keys: 403 Resource not accessible by personal access token`

Use token auth mode:

```bash
export GITHUB_TOKEN=<your_pat>
flux bootstrap github \
  --owner=ivanversluis \
  --repository=homelabs \
  --branch=main \
  --path=clusters/k8s-homelab \
  --personal \
  --private=false \
  --token-auth
```

## 4. Flux validation checklist

Health:

```bash
flux check
flux get all -A
kubectl get all -n flux-system
```

Reconcile manually:

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system --with-source
```

Errors/events:

```bash
flux logs -A --level=error
kubectl get events -n flux-system --sort-by=.lastTimestamp
```

## 5. See exactly what Flux deployed

High-level object tree:

```bash
flux tree kustomization flux-system -n flux-system
```

Inventory (exact objects tracked by Flux):

```bash
kubectl get kustomization flux-system -n flux-system \
  -o jsonpath='{range .status.inventory.entries[*]}{.id}{"\n"}{end}'
```

All Flux CRs:

```bash
kubectl get gitrepositories,kustomizations,helmrepositories,helmreleases,ocirepositories,buckets -A
```

## 6. Headlamp deployment and connectivity checks

Check resources:

```bash
kubectl get ns headlamp
kubectl get pods,svc,ep -n headlamp
```

Important DNS rule:
- Kubernetes service DNS is `<service>.<namespace>.svc.cluster.local`
- For this setup: `headlamp.headlamp.svc.cluster.local`

From inside cluster:

```bash
kubectl run -it --rm dns-test --image=busybox:1.36 --restart=Never -- sh
# inside pod:
nslookup headlamp.headlamp.svc.cluster.local
wget -S -O- http://headlamp.headlamp.svc.cluster.local
```

From local machine (port-forward):

```bash
kubectl port-forward -n headlamp svc/headlamp 8080:80
# open http://localhost:8080
```

## 7. Headlamp login token (ServiceAccount token)

Your manifests already define SA `headlamp` in namespace `headlamp`.

Create token:

```bash
kubectl -n headlamp create token headlamp --duration=24h
```

Paste output token in Headlamp login screen.

Optional permission check:

```bash
kubectl auth can-i get pods --as=system:serviceaccount:headlamp:headlamp -A
```

## 8. Headlamp + Flux plugin validation

In Headlamp:
- Open `Flux` section
- Check `All Controllers Ready`
- Verify Kustomizations/Sources show `Ready=True`
- Confirm revision matches expected Git commit

CLI equivalent:

```bash
flux get kustomizations -A
flux get sources git -A
```

## 9. Interactive terminal in Headlamp

Short answer: **Yes, but only with exec permissions and a shell in the target container.**

Current repo RBAC is read-only (`get/list/watch`) and does not allow `pods/exec`.

Add exec permissions for the Headlamp ServiceAccount:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: headlamp-pod-exec
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create"]
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: headlamp-pod-exec
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: headlamp-pod-exec
subjects:
- kind: ServiceAccount
  name: headlamp
  namespace: headlamp
```

Apply:

```bash
kubectl apply -f headlamp-pod-exec-role.yaml
kubectl apply -f headlamp-pod-exec-binding.yaml
```

Validation:

```bash
kubectl auth can-i create pods/exec --as=system:serviceaccount:headlamp:headlamp -n headlamp
```

Notes:
- Some minimal containers do not include `/bin/sh`; terminal will fail there.
- Prefer namespace-scoped Role/RoleBinding in production instead of broad cluster access.
