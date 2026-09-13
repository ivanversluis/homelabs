# MetalLB

MetalLB provides bare-metal `LoadBalancer` IP assignment for the Kubernetes platform.

- Namespace: `metallb-system`
- Deployment: Flux HelmRelease
- Mode: L2 advertisement
- Configuration: `config/` contains the IPAddressPool and L2Advertisement resources
- Consumers include Kong, Pi-hole, and other Services of type `LoadBalancer`

Upstream documentation: https://metallb.universe.tf/
