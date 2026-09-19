# Kong gateway

## Objective

Kong is the shared ingress and API gateway for the homelab. It terminates TLS, applies route policy, and provides dedicated LLM and MCP request paths without exposing upstream credentials to clients.

## Deployment

Flux reconciles Kong from `services/gateway/kong/` through `clusters/k8s-homelab/services/kong-kustomization.yaml`. The deployment source of truth is `core/kong-helmrelease.yaml`, which uses the official Kong Helm chart. `bootstrap/` is a separate, ordered Flux reconciliation unit for the namespace and ExternalSecrets that must exist before Kong admission validates dependent resources. MCP routes reconcile separately through `kong-mcp-gateway` after the AI backends exist.

- Namespace: `kong`
- IngressClass: `kong`
- Proxy: MetalLB LoadBalancer
- Ports: HTTP/80 and HTTPS/443
- TLS: cert-manager wildcard certificate for `${DOMAIN}` and `*.${DOMAIN}`
- Admin API: TLS-only ClusterIP
- Configuration: database-less, driven by Kubernetes resources
- Dependencies: MetalLB, cert-manager, External Secrets Operator, and Vault-backed secret data

## Gateway boundaries

The gateway use cases have separate routing and ownership boundaries.

| Use case | Current hostname | Configuration ownership | Notes |
|---|---|---|---|
| General API gateway | `api-gw.${DOMAIN}` | Gateway resources and complete upstream integrations live in `api-gateway/` | `/healthz` identifies the boundary and `/mikrotik` exposes the authenticated RouterOS API proxy. |
| LLM gateway | `llm-gw.${DOMAIN}` | Shared LLM services, routes, authentication, and plugins live in `llm-gateway/`; clients live with their workloads | Open WebUI and OpenClaw use `https://llm-gw.${DOMAIN}/openai/v1`. |
| MCP gateway | `mcp-gw.${DOMAIN}` | Each complete MCP upstream integration lives below `mcp-gateway/`, including backend, route, plugins and required bootstrap secrets | Open WebUI uses `/kubernetes` and `/nmap` on this host. |

This layout follows the repository ownership model: Kong supplies the shared runtime capability, while a workload owns its routes and workload-specific policy.

## Hostname and ownership decision

Dedicated API, LLM and MCP hostnames make client intent, route policy, logging, and publication rules explicit. The contracts are `api-gw.${DOMAIN}`, `llm-gw.${DOMAIN}` and `mcp-gw.${DOMAIN}`; all three are published in cluster split-brain DNS. Legacy gateway hostnames are not configured.

Each gateway's boundary Ingress owns TLS/SNI registration for its hostname. Route-only Ingresses must not duplicate `tls.hosts` entries for the wildcard secret; overlapping certificate declarations previously caused KIC synchronization failures.

Keep configuration grouped by responsibility rather than forcing every route into one folder:

```text
services/gateway/kong/
|-- api-gateway/            # general API hostname and upstream integrations
|   `-- routeros-upstream/  # RouterOS service, route, plugins and consumer
|-- bootstrap/              # ordered namespace and ExternalSecrets
|-- core/                   # Helm release, ingress class, TLS and shared policy
|-- llm-gateway/            # LLM routes, authentication and translation
`-- mcp-gateway/            # MCP gateway hostname and upstream integrations
    |-- kubernetes-upstream/
    `-- nmap-upstream/
```

An upstream folder owns the full gateway integration: backend or external Service abstraction, Ingress, route-specific plugins, consumer and related secret declarations. Bootstrap subfolders are separate Flux reconciliation stages only where an ExternalSecret must become Ready before Kong admission evaluates a consumer or `configFrom` reference.

`kong-routeros-bootstrap` waits for both RouterOS ExternalSecrets after the monitoring namespace exists, then `kong-routeros` applies its upstream, plugins, route and Gatus consumer. `kong-mcp-bootstrap` waits for the MCP upstream secrets after the AI namespace exists, then `kong-mcp-gateway` applies both MCP upstreams and their Kong configuration.

## Migration

The hostname cutover is immediate: Git-managed clients and cluster DNS use only the three gateway hostnames. Validate authentication, rate limits, upstream TLS and logs after reconciliation. External clients must be updated at the same time because no legacy hostname routes remain.

## Validation

Render and inspect the affected Kustomizations before merge. After Flux reconciliation, validate without printing secret values:

```bash
kubectl -n flux-system get kustomization kong kong-bootstrap kong-routeros-bootstrap kong-routeros kong-mcp-bootstrap kong-mcp-gateway
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
