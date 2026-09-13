# Copilot Instructions (homelabs)

This repository allows Copilot Agents, but external source trust is deny-by-default.

## Repository Ownership Model

Classify Kubernetes content by architectural responsibility, not by installation mechanism. The authoritative model is `docs/repository-layout.md`.

- `platform/` - Kubernetes system capabilities and cluster-wide controllers.
- `infra/` - supporting infrastructure and management software running on the platform.
- `services/` - shared runtime services consumed by clients or workloads.
- `workloads/apps/` - application workloads.
- `workloads/vms/` - KubeVirt virtual-machine workloads.
- `clusters/k8s-homelab/platform/` - dedicated platform Flux reconciliation objects.
- `clusters/k8s-homelab/workloads/` - existing workload Flux reconciliation objects; keep their identities stable.

Do not recreate the legacy workload roots `apps/`, `vms/`, or `clusters/k8s-homelab/apps/` after Wave 2.

Repository paths and Vault secret paths are separate contracts. Do not rename existing Vault keys merely because a manifest moved.

## GitOps Migration Safety

A filesystem move is not automatically a safe GitOps ownership move.

1. For path-only refactors, preserve Flux `Kustomization` metadata.name, dependencies, prune/force settings, postBuild, sourceRef, namespaces, and resource content. Change only `spec.path` and repository file locations.
2. If live resources change Flux owner, stop and create a staged ownership-transfer plan: protect/disable prune, reconcile, adopt with the new owner, verify live inventory/labels, remove from the old owner, then restore prune.
3. Treat Namespace, CRD, PVC, StorageClass, operator CR, and stateful ownership changes as destructive-risk.
4. Any P1 review finding involving pruning, inventory, namespace deletion, ownership, or persistence is a merge blocker. A COMMENTED automated review is not equivalent to approval.
5. For Wave 2 validation follow `docs/lifecycle/wave2-workloads.md` and report live inventory checks before recommending merge.

## External Source Safety Policy

1. Never execute remote manifests/scripts directly from URLs.
2. Never run `kubectl apply -f <http-url>`, `kubectl create -f <http-url>`, `curl ... | sh`, or `wget ... | bash`.
3. For any external manifest/script/image source:
   - pin an explicit version/tag/digest;
   - download locally first;
   - review source and contents;
   - verify integrity/authenticity when possible;
   - ask for user confirmation before cluster apply/execute.
4. Prefer official docs/release channels and vendor-maintained registries.
5. If validation evidence is missing, stop before cluster changes.

## Kubernetes Security Skill Mapping

Treat `.claude/skills/kubernetes-security-policies/` as reusable guidance for Pod Security Standards, NetworkPolicies, RBAC, admission control, secrets, and image security.
