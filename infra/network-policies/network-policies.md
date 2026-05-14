# Network Policies Homelab wiki

## Documentation
https://docs.tigera.io/calico/latest/network-policy/

## Repo
N/A (custom Calico policies)

## Releases
N/A

## Latest version
N/A

## Objective
As home-admin I want Zero Trust network segmentation so that all namespaces have default-deny ingress and egress, with explicit allow rules per workload.

## Implementation
Global default-deny policy using Calico GlobalNetworkPolicy. Per-namespace Kubernetes NetworkPolicies provide explicit allow rules that override the global deny.

## Stack
Calico GlobalNetworkPolicy + Kubernetes NetworkPolicy (Kustomize via Flux)

## LLD
- Scope: All namespaces except system (kube-system, kube-public, calico-system, longhorn-system, metallb-system, etc.)
- Policy: zt-default-deny (order 1000) — denies all ingress + egress
- Override: per-namespace k8s NetworkPolicies with explicit Allow rules (co-located with each component)
- This directory only contains: `global/` (cluster-wide default-deny) and `flux-system-netpol.yaml`
- All other per-namespace policies live alongside their component manifests (`<name>-netpol.yaml`)
- Dependencies: Calico CNI (Tigera Operator)
