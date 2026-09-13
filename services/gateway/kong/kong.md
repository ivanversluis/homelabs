# Kong Homelab wiki

## Documentation
https://docs.konghq.com/gateway/latest/

## Repo
https://github.com/Kong/kong

## Releases
https://artifacthub.io/packages/helm/kong/kong

## Latest version
Helm chart 2.46.x (Kong OSS 3.7+)

## Objective
As home-admin I want an API gateway and ingress controller that provides TLS termination, rate limiting, AI prompt guard, and AI proxy capabilities for all homelab services.

## Implementation
Deployed via Flux HelmRelease using the official Kong Helm chart. Configured as both an ingress controller and AI Gateway with plugins for rate limiting, prompt guard, and AI proxy to Azure OpenAI.

## Stack
Helm (FluxCD HelmRelease)

## LLD
- Namespace: kong
- Helm chart: kong v2.46.x
- Proxy: MetalLB LoadBalancer (KONG_LB_IP)
- Ports: HTTP/80, HTTPS/443
- TLS: cert-manager wildcard certificate
- Plugins: ai-proxy, ai-prompt-guard, rate-limit, normalize-model-name
- Dependencies: MetalLB, cert-manager, ExternalSecret (Vault) for Azure AI keys
