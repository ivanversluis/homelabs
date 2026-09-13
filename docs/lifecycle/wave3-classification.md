# Wave 3 - Classification Refactor Validation

## Goal

Wave 3 aligns repository location with architectural responsibility without changing live GitOps ownership.

Approved moves:

- `infra/kong/` -> `services/gateway/kong/`
- `infra/home-exporters/` -> `services/telemetry/home-exporters/`
- `infra/ai/` -> `workloads/apps/ai/`
- `clusters/k8s-homelab/infra/kong-kustomization.yaml` -> `clusters/k8s-homelab/services/`
- `clusters/k8s-homelab/infra/home-exporters-kustomization.yaml` -> `clusters/k8s-homelab/services/`
- `clusters/k8s-homelab/infra/identity-ingress-kustomization.yaml` -> `clusters/k8s-homelab/services/`
- `clusters/k8s-homelab/infra/ai-kustomization.yaml` -> `clusters/k8s-homelab/workloads/`
- legacy Synology Portainer Compose -> `clusters/synology/workloads/apps/portainer/`
- `plan/sc-migration.sh` -> `scripts/lifecycle/storage-class-migration.sh`

`infra/openclaw/` intentionally remains infrastructure because it is a Kubernetes operations agent.

## Safety invariant

This is a path-only GitOps refactor. The existing Flux Kustomization objects remain the owners of their current live inventories.

Expected Flux identities:

- `Kustomization/kong`
- `Kustomization/home-exporters`
- `Kustomization/identity-ingress`
- `Kustomization/ai`

Do not merge if validation shows an ownership transfer, resource recreation, namespace prune, PVC prune, or semantic manifest change.

## Expected source paths

```text
kong             ./services/gateway/kong
home-exporters   ./services/telemetry/home-exporters
identity-ingress ./services/identity/kong-ingress
ai               ./workloads/apps/ai
```

`ai` must continue to depend on `kong`.

## 1. Repository structure

```bash
test ! -e infra/kong
test ! -e infra/home-exporters
test ! -e infra/ai
test -d services/gateway/kong
test -d services/telemetry/home-exporters
test -d workloads/apps/ai
test -f clusters/synology/workloads/apps/portainer/stack-portainer-ee.yml
test ! -e workloads/apps/portainer
test -f scripts/lifecycle/storage-class-migration.sh
test ! -e plan/sc-migration.sh
```

Verify that `clusters/synology/` is not referenced by `clusters/k8s-homelab/kustomization.yaml`.

## 2. Find stale operational paths

```bash
git grep -n 'infra/kong'
git grep -n 'infra/ai'
git grep -n 'infra/home-exporters'
git grep -n 'workloads/apps/portainer'
git grep -n 'plan/sc-migration.sh'
```

Classify every hit:

1. repository path that must be updated;
2. historical documentation that is intentionally retained;
3. Vault/secret path that must remain unchanged.

Never rename a Vault key solely because a repository path moved.

## 3. Compare moved content

Use a clean worktree for `main` and compare old and new trees.

```bash
git diff main...HEAD --summary --find-renames

diff -ru <main-worktree>/infra/kong services/gateway/kong
diff -ru <main-worktree>/infra/home-exporters services/telemetry/home-exporters
diff -ru <main-worktree>/infra/ai workloads/apps/ai
```

The three source trees must be content-equivalent except for intentional repository-path comments/documentation.

## 4. Render validation

```bash
kustomize build clusters/k8s-homelab >/tmp/wave3-cluster.yaml
kustomize build services/gateway/kong >/dev/null
kustomize build services/telemetry/home-exporters >/dev/null
kustomize build workloads/apps/ai >/dev/null
kustomize build services/identity/kong-ingress >/dev/null
```

If practical, render the old paths from a `main` worktree and compare normalized YAML with the new paths. Unexpected semantic differences are blockers.

## 5. Flux object invariant check

```bash
for ks in kong home-exporters identity-ingress ai; do
  echo "===== $ks ====="
  kubectl get kustomization "$ks" -n flux-system -o yaml
  flux tree ks "$ks" -n flux-system
done
```

Before merge, the live cluster will still show the old source paths because `main` has not changed. Confirm that the PR changes only `spec.path` and file organization for these Flux objects.

Check the PR version of each Kustomization preserves:

- `metadata.name`
- namespace
- `prune`
- `force`
- `sourceRef`
- `dependsOn`
- `postBuild`
- intervals/timeouts/retries

## 6. Root inventory / duplicate ownership check

```bash
flux tree ks flux-system -n flux-system
```

Confirm the root `flux-system` Kustomization does not directly own resources that should remain under `kong`, `home-exporters`, `identity-ingress`, or `ai`.

Duplicate ownership is a blocker.

## 7. Read-only Flux diff

Inspect CLI help first and use only the installed read-only diff capability:

```bash
flux diff kustomization --help
```

Diff each Wave 3 owner against the PR source if supported by the installed Flux CLI.

Expected result: source relocation only. Any planned deletion/recreation of Namespace, PVC, Deployment, Service, ExternalSecret, HelmRelease, Kong CR, or other workload resource is a blocker.

Do not reconcile the PR branch into the live cluster during review.

## 8. Synology boundary

`clusters/synology/workloads/apps/portainer/` currently stores the existing Synology Container Manager / Docker Compose definition for later redesign.

Verify:

- it is not referenced from `clusters/k8s-homelab/`;
- it is not included by a Flux Kustomization;
- Wave 3 does not deploy or remove anything on Synology;
- the active Kubernetes Portainer remains `infra/portainer/`.

## 9. Renovate coverage

Verify Renovate scans Kubernetes/Flux manifests under all active declarative roots:

- `platform/`
- `infra/`
- `services/`
- `workloads/`
- `clusters/`

The custom split image repository/tag manager must not assume HelmReleases only exist under `infra/`.

## 10. Automated review gate

Run a fresh Copilot/Codex review against the final commit.

Treat any P1/P2 finding involving these topics as a merge blocker:

- Flux inventory or prune
- namespace deletion
- PVC or persistent data
- ownership transfer or duplicate ownership
- missing/stale operational repository path
- broken Kustomize render
- changed runtime manifest content
- Synology content accidentally wired into Kubernetes Flux

A review state of `COMMENTED` does not mean the change is safe.

## Required validation report

Return:

```text
Check | PASS/BLOCKER | Evidence
```

Cover at minimum:

- repository structure
- stale path audit
- source-tree equivalence
- Kustomize renders
- Flux Kustomization invariants
- root inventory / duplicate ownership
- read-only Flux diff
- Synology isolation
- Renovate coverage
- automated review findings

Finish with exactly one of:

```text
MERGE SAFE
```

or

```text
DO NOT MERGE
```
