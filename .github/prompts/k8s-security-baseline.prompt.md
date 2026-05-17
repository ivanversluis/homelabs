---
mode: ask
---
Use the kubernetes-security-engineer mindset for this repository.

Goal:
- Audit and harden Kubernetes manifests for Pod Security, NetworkPolicy, RBAC, SecurityContext, secrets, and image security.

Process:
1. Scan changed or selected Kubernetes manifests.
2. Report findings by severity with file paths.
3. Propose concrete patch-ready fixes.
4. Do not execute or recommend direct apply from remote URLs.
5. For external sources, require pinning + local review + integrity/provenance checks + user confirmation.

Output format:
- Critical findings
- High findings
- Medium findings
- Suggested patches
- Validation commands
