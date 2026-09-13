# Copilot Instructions (homelabs)

This repository allows Copilot Agents, but external source trust is deny-by-default.

## Repository Ownership Model

Classify Kubernetes content by architectural responsibility, not by installation mechanism. The authoritative model is documented in `docs/repository-layout.md`.

- `platform/` — Kubernetes system capabilities and cluster-wide controllers: networking/CNI, cluster DNS, LoadBalancer implementation, storage/CSI, virtualization, observability, certificates, External Secrets, and network-policy baseline.
- `infra/` — supporting infrastructure and management software that runs on the platform, such as Vault, Kong, Headlamp, Portainer, SemaphoreUI, OpenClaw, and AI tooling.
- `services/` — shared runtime services consumed by clients or workloads, such as Authentik, Pi-hole, Unbound, and Cloudflare Tunnel.
- `apps/` and `vms/` — workload locations. These remain unchanged until the dedicated workload restructuring wave.
- `clusters/k8s-homelab/platform/` — Flux reconciliation objects for platform components that need dedicated ordering, substitution, state, or safety boundaries.

Use the current repository tree and `docs/repository-layout.md` as the source of truth. Do not recreate legacy platform locations such as `services/network/calico`, `services/storage/longhorn`, `services/lb/metallb`, `infra/coredns`, `infra/network-policies`, `infra/observability`, `infra/monitoring`, `infra/kubevirt`, `infra/cdi`, `infra/cert-manager`, `infra/external-secrets`, or `infra/local-path-provisioner`.

Repository paths and Vault secret paths are separate contracts. Do not rename existing Vault keys merely because a manifest moved into `platform/`.

## External Source Safety Policy

1. Never execute remote manifests/scripts directly from URLs.
2. Never run `kubectl apply -f <http-url>`, `kubectl create -f <http-url>`, `curl ... | sh`, or `wget ... | bash`.
3. For any external manifest/script/image source, require this sequence:
   - Pin an explicit version/tag/digest (no floating `latest` or `master` when avoidable).
   - Download to a local file first.
   - Review file content and source ownership/reputation.
   - Verify integrity/authenticity when possible (checksum/signature/provenance).
   - Ask for user confirmation before cluster apply/execute.
4. Prefer official docs/release channels and vendor-maintained registries.
5. If validation evidence is missing, stop and ask for approval before proceeding.

## Kubernetes Security Skill Mapping

Treat `.claude/skills/kubernetes-security-policies/` as reusable guidance for:
- Pod Security Standards (PSA/PSS)
- NetworkPolicies and zero-trust segmentation
- RBAC least privilege
- Admission control (Gatekeeper/Kyverno)
- Secrets and image security

When asked to "use predefined skills", apply this guidance directly in Copilot responses and edits.
