# Load Balancer (MetalLB) Homelab wiki

## Documentation
https://metallb.universe.tf/

## Repo
https://github.com/metallb/metallb

## Releases
https://artifacthub.io/packages/helm/metallb/metallb

## Latest version
Helm chart 0.14.x

## Objective
As home-admin I want bare-metal LoadBalancer IP assignment so that Kubernetes Services of type LoadBalancer get real LAN IPs accessible from the home network.

## Implementation
Deployed via Flux HelmRelease. Provides L2 advertisement for assigned IP pools. Used by Kong, Pi-hole, and other services requiring external IPs.

## Stack
Helm (FluxCD HelmRelease)

## LLD
- Namespace: metallb-system
- Helm chart: metallb v0.14.x
- Components: Controller + Speaker (DaemonSet)
- Configuration: IPAddressPool + L2Advertisement (separate metallb-config)
- Consumers: Kong (KONG_LB_IP), Pi-hole (172.16.20.215)
- Dependencies: None (foundational networking)
