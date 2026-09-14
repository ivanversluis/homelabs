# Kong gateway

## Objective

Kong is the shared ingress and API gateway for the homelab. It terminates TLS, applies route policy, and provides dedicated LLM and MCP request paths without exposing upstream credentials to clients.

## Deployment

Flux reconciles Kong from `services/gateway/kong/` through `clusters/k8s-homelab/services/kong-kustomization.yaml`. The deployment source of truth is `kong-helmrelease.yaml`, which uses the official Kong Helm chart. `bootstrap/` is a separate, ordered Flux reconciliation unit for the namespace and ExternalSecrets that must exist before Kong admission validates dependent resources.

Do not treat `kong-values.yaml` as the active Flux configuration. It is a legacy standalone Helm values file pending a separate reference/use audit.

- Namespace: `kong`
- IngressClass: `kong`
- Proxy: MetalLB LoadBalancer
- Ports: HTTP/80 and HTTPS/443
- TLS: cert-manager wildcard certificate for `${DOMAIN}` and `*.${DOMAIN}`
- Admin API: TLS-only ClusterIP
- Configuration: database-less, driven by Kubernetes resources
- Dependencies: MetalLB, cert-manager, External Secrets Operator, and Vault-backed secret data

## Current gateway boundaries

The three gateway use cases already have different routing and ownership boundaries. They do not yet use the proposed `api-gw`, `llm-gw`, and `mcp-gw` names.

| Use case | Current hostname | Configuration ownership | Notes |
|---|---|---|---|
| General API and ingress | Application hostnames | Each service or workload owns its Ingress; Kong provides the shared `kong` IngressClass and global policy resources | There is no single generic API endpoint to rename safely. |
| LLM gateway | `ai.${DOMAIN}` | Shared LLM services, routes, authentication, and plugins live in `services/gateway/kong/`; clients live with their workloads | Open WebUI and OpenClaw currently use `https://ai.${DOMAIN}/openai/v1`. |
| MCP gateway | `mcp.${DOMAIN}` | MCP services, Ingresses, and route-specific plugins live in `workloads/apps/ai/mcp/`; shared rate limiting comes from Kong | Open WebUI currently uses `/kubernetes` and `/nmap` on this host. |

This layout follows the repository ownership model: Kong supplies the shared runtime capability, while a workload owns its routes and workload-specific policy.

## Hostname and folder decision

Dedicated LLM and MCP hostnames are useful security and operational boundaries because they make client intent, route policy, logging, and future publication rules explicit. The repository already has those boundaries as `ai.${DOMAIN}` and `mcp.${DOMAIN}`.

A change to the proposed hostnames is deferred until these runtime decisions are confirmed:

1. Whether `api-gw.${DOMAIN}` is an operator endpoint, a shared API namespace, or merely an alias for all application-owned Ingresses.
2. Which new hostnames must be available on LAN DNS, through Cloudflare Tunnel, or both.
3. Which clients outside this repository depend on the existing `ai.${DOMAIN}` and `mcp.${DOMAIN}` names.
4. Which Ingress owns TLS/SNI registration for each new hostname.

The TLS certificate already covers the proposed subdomains, but Kong Ingress Controller still needs an unambiguous SNI owner. Do not add duplicate `tls.hosts` entries for the shared wildcard secret across multiple Ingress objects. The repository previously experienced KIC synchronization failures from overlapping certificate declarations.

A folder split is also deferred. Moving manifests beneath `services/gateway/kong/` can be a path-only refactor under the existing Flux `kong` Kustomization, but MCP route resources should remain workload-owned unless a deliberate GitOps ownership transfer is designed. Folder symmetry is not enough reason to move live resource ownership.

## Proposed target

Once the prerequisites are confirmed, prefer these stable public contracts:

- General API gateway: `api-gw.${DOMAIN}`, only if a concrete shared API route contract is defined.
- LLM gateway: `llm-gw.${DOMAIN}`.
- MCP gateway: `mcp-gw.${DOMAIN}`.

Keep configuration grouped by responsibility rather than forcing every route into one folder:

```text
services/gateway/kong/
|-- core/        # HelmRelease, IngressClass, TLS, network policy
|-- llm/         # shared LLM services, routes, auth, and plugins
`-- bootstrap/   # ordered namespace and ExternalSecrets

workloads/apps/ai/mcp/
|-- mcp-kubernetes/
`-- mcp-nmap/
```

MCP Ingresses can use `mcp-gw.${DOMAIN}` while remaining next to their backends and workload-specific plugins.

## Migration

Use an additive migration so existing clients keep working:

1. Confirm the hostname publication scope and external client inventory.
2. Add the new LAN DNS records and, only where required, Cloudflare Tunnel routes.
3. Add each new hostname as an alias on the existing route. Register its SNI in exactly one Ingress.
4. Validate old and new hostnames in parallel, including authentication, rate limits, upstream TLS, and logs.
5. Update Git-owned clients first, then any confirmed external clients.
6. Observe a defined compatibility period before removing the old hostname.
7. Consider the folder-only refactor separately after routing is stable, keeping the existing Flux reconciliation identities.

Do not combine hostname cutover, folder movement, secret migration, and Flux ownership transfer in one change.

## Validation

Render and inspect the affected Kustomizations before merge. After Flux reconciliation, validate without printing secret values:

```bash
kubectl -n flux-system get kustomization kong kong-bootstrap
kubectl -n kong get helmrelease kong
kubectl -n kong get ingress
kubectl -n ai get ingress
```

For a hostname migration, test both old and new names with the existing internal client credentials. Confirm the wildcard certificate is served, unauthorized requests are rejected, authorized LLM model discovery and completion work, both MCP paths respond, and no KIC configuration-sync errors appear.

## Rollback

During the compatibility period, rollback is limited to restoring clients to the old hostname and removing the new alias and its DNS or tunnel entry. Revert the Git change so route, client, and documentation changes return together. If a later folder-only refactor fails, revert the path and `kustomization.yaml` references while preserving the same Flux Kustomization and resource identities.

## References

- [Kong Gateway documentation](https://docs.konghq.com/gateway/latest/)
- [Kong source repository](https://github.com/Kong/kong)
- [Kong Helm chart](https://artifacthub.io/packages/helm/kong/kong)
