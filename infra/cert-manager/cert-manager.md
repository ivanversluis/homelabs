# cert-manager Homelab wiki

## Documentation
https://cert-manager.io/docs/

## Repo
https://github.com/cert-manager/cert-manager

## Releases
https://artifacthub.io/packages/helm/cert-manager/cert-manager

## Latest version
v1.17.x

## Objective
As home-admin I want automated TLS certificate issuance and renewal for all homelab services using Let's Encrypt and wildcard certificates.

## Implementation
Deployed via Flux HelmRelease with CRDs installed. Provides wildcard certificates consumed by Kong ingress for all *.DOMAIN services.

## Stack
Helm (FluxCD HelmRelease)

## LLD
- Namespace: cert-manager
- Helm chart: cert-manager v1.17.x
- CRDs: installed
- Prometheus metrics: enabled
- Dependencies: None (foundational service, consumed by Kong and other ingresses)

## FAQ

**Why doesn't cert-manager just use the cluster's own CoreDNS to check if a DNS-01 TXT record has propagated?**
By default it does (pods use CoreDNS via the cluster's `/etc/resolv.conf`). The problem is CoreDNS is a
*recursive/caching* resolver, not authoritative — when cert-manager walks the domain hierarchy to find who
is authoritative for the zone (so it can ask them directly whether the TXT record is live yet), CoreDNS's
`forward` plugin can hand back an NS delegation from an intermediate level (e.g. the `.tech` TLD registry
nameservers) instead of the real zone's nameservers (Cloudflare). cert-manager then queries those wrong
servers forever and the challenge never leaves "not yet propagated". This is a known cert-manager +
Kubernetes-DNS gotcha, which is exactly why `dns01RecursiveNameservers` /
`dns01RecursiveNameserversOnly` exist: they tell cert-manager to bypass the in-cluster resolver entirely for
this specific self-check and talk directly to public recursive resolvers (1.1.1.1 / 8.8.8.8) instead.
