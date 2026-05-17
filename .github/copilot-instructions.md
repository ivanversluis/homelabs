# Copilot Instructions (homelabs)

This repository allows Copilot Agents, but external source trust is deny-by-default.

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
