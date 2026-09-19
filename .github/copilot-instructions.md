# Copilot Instructions (homelabs)

This repository allows Copilot Agents, but external source trust is deny-by-default.

## Repository Ownership Model

Classify Kubernetes content by architectural responsibility, not by installation mechanism. The authoritative model is `docs/repository-layout.md`.

- `platform/` - Kubernetes system capabilities and cluster-wide controllers that make Kubernetes work.
- `infra/` - homelab operations and management control plane: GitOps, cluster administration, infrastructure automation, secrets backend, operational agents.
- `services/` - shared runtime/data-plane capabilities consumed by clients, workloads, or platform components.
- `workloads/apps/` - application/use-case workloads primarily consumed by a user.
- `workloads/vms/` - KubeVirt virtual-machine workloads.
- `clusters/k8s-homelab/platform/` - dedicated platform Flux reconciliation objects.
- `clusters/k8s-homelab/services/` - dedicated shared-service Flux reconciliation objects.
- `clusters/k8s-homelab/workloads/` - dedicated workload Flux reconciliation objects.
- `clusters/synology/` - Synology-specific desired state and legacy/container-service definitions. This tree is not part of the `k8s-homelab` Flux root unless explicitly wired in a future change.

Wave 3 canonical examples:

- Kong Gateway: `services/gateway/kong/`
- Home telemetry exporters: `services/telemetry/home-exporters/`
- AI/Open WebUI + MCP use case: `workloads/apps/ai/`
- OpenClaw Kubernetes operations agent: `infra/openclaw/`
- Kubernetes management UIs/tools such as Headlamp and Portainer: `infra/`
- Legacy Synology Portainer Compose definition: `clusters/synology/workloads/apps/portainer/`

Do not recreate the legacy roots `apps/`, `vms/`, `clusters/k8s-homelab/apps/`, `infra/kong/`, `infra/ai/`, or `infra/home-exporters/` after their migration waves.

Repository paths and Vault secret paths are separate contracts. Do not rename existing Vault keys merely because a manifest moved. In particular, Wave 3 does not rename existing `infra/kong`, `infra/home-exporters`, or AI-related Vault keys.

## GitOps Migration Safety

A filesystem move is not automatically a safe GitOps ownership move.

1. For path-only refactors, preserve Flux `Kustomization` `metadata.name`, dependencies, prune/force settings, postBuild, sourceRef, namespaces, and rendered resource content. Change only `spec.path` and repository file locations.
2. If live resources change Flux owner, stop and create a staged ownership-transfer plan: protect/disable prune, reconcile, adopt with the new owner, verify live inventory/labels, remove from the old owner, then restore prune.
3. Treat Namespace, CRD, PVC, StorageClass, operator CR, and stateful ownership changes as destructive-risk.
4. Any P1/P2 review finding involving pruning, inventory, namespace deletion, ownership, persistence, or unintended resource recreation is a merge blocker. A COMMENTED automated review is not equivalent to approval.
5. For Wave 2 validation follow `docs/lifecycle/wave2-workloads.md`.
6. For Wave 3 validation follow `docs/lifecycle/wave3-classification.md`. Do not recommend merge until its static and live read-only checks are complete.

## Admission-Webhook Bootstrap Safety - NON-NEGOTIABLE

Flux/Kustomize reconciliation must never rely on creation order inside one rendered Kustomization when admission validation requires a referenced object to already exist.

Flux performs server-side dry-run/admission validation before applying the rendered resource set. Therefore a producer and a webhook-validated consumer can deadlock if they are introduced in the same Flux `Kustomization`.

Canonical failure pattern:

```text
ExternalSecret -> asynchronously creates Secret
KongConsumer   -> validating webhook requires that Secret to exist at admission time
```

If both are rendered by the same Flux `Kustomization`, the KongConsumer dry-run is rejected because the Secret does not exist. The reconcile aborts before the ExternalSecret is applied, so retrying cannot bootstrap the dependency.

Rules for every change:

1. Before adding any CR that references another resource, determine whether an admission webhook validates that reference at CREATE/UPDATE time.
2. Do not assume file order, Kustomize resource order, server-side apply order, or a later retry will satisfy such a dependency.
3. If resource B must already exist for resource A to pass admission, B must be materialized in an earlier reconciliation boundary or already exist before A is introduced.
4. Use separate Flux `Kustomization` objects with explicit `dependsOn` for bootstrap prerequisites versus webhook-validated consumers when required.
5. For generated prerequisites such as `ExternalSecret -> Secret`, the producing Flux Kustomization must use readiness/wait semantics sufficient to prove the generated object exists before the consuming Kustomization runs.
6. Explicitly review bootstrap-sensitive resources including `ExternalSecret`, Secret-backed `KongConsumer` credentials, `KongPlugin.configFrom`, webhook-validated CR references, CRD/controller dependencies, certificates/secrets, and operator-generated resources.
7. Validation must include a clean-cluster/bootstrap thought experiment: would this reconcile succeed if none of the newly generated resources already existed? A design that only works because a Secret/resource happens to exist in the current cluster is invalid.
8. Any same-reconciliation producer/consumer cycle involving an admission webhook is a merge blocker.

Required review question before merge:

> Does any resource in this Flux Kustomization require another resource from the same Kustomization to already exist before server-side dry-run/admission can succeed?

If the answer is yes or uncertain, stop and split/stage the reconciliation before merge.

## Wave 3 Non-Negotiable Invariants

- Flux object names remain `kong`, `home-exporters`, `identity-ingress`, and `ai`.
- `kong` source path is `./services/gateway/kong`.
- `home-exporters` source path is `./services/telemetry/home-exporters`.
- `identity-ingress` remains the same Flux object and still targets `./services/identity/kong-ingress`.
- `ai` source path is `./workloads/apps/ai` and still depends on `kong`.
- No Namespace, PVC, Deployment, Service, NetworkPolicy, ExternalSecret, HelmRelease, Kong CR, or other live resource should change semantically due to Wave 3.
- `clusters/synology/workloads/apps/portainer/` is repository organization only and must not be added to the `k8s-homelab` Flux root.
- `infra/openclaw/` remains infrastructure because it is a Kubernetes operations agent; do not move it to workloads as part of Wave 3.

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
