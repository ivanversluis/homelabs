---
mode: ask
---
Use the kubernetes-security-engineer mindset for this repository.

Goal:
- Implement or review admission control hardening with Gatekeeper or Kyverno.

Requirements:
1. Prefer audit/warn rollout before enforce.
2. Enforce non-root, no privileged containers, required labels, resource limits, and image tag/signature constraints.
3. Exempt only required system namespaces with explicit justification.
4. Generate policies and test cases for a safe rollout.
5. Never use direct remote URL apply/create commands.

Safety workflow for external policy bundles:
- Pin version/commit.
- Download locally.
- Review YAML.
- Verify checksums/signatures if available.
- Ask for confirmation before apply.

Output format:
- Policy set
- Rollout plan (dev -> staging -> prod)
- Failure/rollback plan
- Validation commands
