# DNS Service (Pi-hole + Unbound) Homelab wiki

## Documentation
- Pi-hole: https://docs.pi-hole.net/
- Unbound: https://unbound.docs.nlnetlabs.nl/en/latest/

## Repo
https://github.com/pi-hole/pi-hole

## Releases
https://hub.docker.com/r/pihole/pihole

## Latest version
Pi-hole 2026.04.0

## Objective
As home-admin I want network-wide ad blocking and recursive DNS resolution so that all devices get clean DNS without relying on external resolvers.

## Implementation
Pi-hole deployed as a Kubernetes Deployment with MetalLB LoadBalancer IP. Unbound provides recursive DNS resolution upstream of Pi-hole for full DNSSEC validation.

## Stack
Kubernetes Deployment (Kustomize via Flux)

## LLD
- Namespace: pihole
- Image: docker.io/pihole/pihole:2026.04.0
- Ports: tcp+udp/53 (DNS), tcp/80 (web UI)
- Service: LoadBalancer (MetalLB, IP 172.16.20.215)
- Upstream: unbound.dns.svc.cluster.local
- Features: DNSSEC enabled, query logging
- Volume: PVC for Pi-hole data
- Dependencies: MetalLB, ExternalSecret (Vault) for web password
