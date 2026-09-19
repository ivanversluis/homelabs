# CoreDNS Homelab wiki

## Documentation
https://coredns.io/manual/toc/

## Repo
https://github.com/coredns/coredns

## Releases
https://github.com/coredns/coredns/releases

## Latest version
Cluster default (managed by Kubernetes)

## Objective
As home-admin I want split-brain DNS resolution so that internal homelab domains resolve to the Kong LoadBalancer IP from within the cluster, avoiding hairpin NAT issues.

## Implementation
Custom CoreDNS ConfigMap managed by Flux with hosts{} block for internal domain resolution. Flux substitution injects DOMAIN and KONG_LB_IP from flux-domain-vars Secret.

## Stack
ConfigMap override (Kustomize via Flux)

## LLD
- Namespace: kube-system
- Resource: ConfigMap (coredns)
- Port: tcp+udp/53
- Substitution: ${DOMAIN}, ${KONG_LB_IP} via Flux postBuild
- Safety: prune: false (never deleted by Flux)
- Dependencies: Flux flux-domain-vars Secret
