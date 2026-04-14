# homelabs

Personal bare-metal Kubernetes homelab, managed with Flux GitOps.

## Hardware

4× HP EliteDesk 800 G9 Mini PC — Intel i5-12600 · 16 GB RAM · 256 GB NVMe · Arch Linux

| Node          | Role          |
|---------------|---------------|
| k8s-master01  | Control Plane |
| k8s-worker01  | Worker        |
| k8s-worker02  | Worker        |
| k8s-worker03  | Worker        |

## Repo layout

- `clusters/k8s-homelab` — cluster entrypoint + Flux bootstrap
- `infra` — shared platform components (vault, monitoring, external-secrets, etc.)
- `services` — core services (DNS, storage, LB, identity, tunnel)
- `apps` — user workloads (`linkding`, `n8n`, `termix`)
- `scripts` — host/bootstrap helper scripts

## Stack

| Component      | Current in repo                     | Roadmap |
|----------------|-------------------------------------|---------|
| OS             | Arch Linux                          | —       |
| GitOps         | Flux (Kustomize + HelmRelease)      | —       |
| LB             | MetalLB                             | kube-vip (planned) |
| Storage        | Longhorn                            | —       |
| DNS            | Pi-hole + Unbound                   | —       |
| Secrets        | Vault + External Secrets            | —       |
| Identity       | Authentik                           | —       |
| Tunnel         | Cloudflare Tunnel                   | —       |
| Monitoring     | kube-prometheus-stack + metrics-server | —    |

## Architecture

```mermaid
flowchart TB
  subgraph LAN["Home LAN / RouterOS"]
    R["RouterOS\nFirewall + Inter-VLAN routing"]
    IOTV["IoT VLAN"]
    MGMTV["Mgmt VLAN"]
  end

  subgraph K8S["Kubernetes Cluster · Arch Linux"]
    CP["k8s-master01\nControl Plane"]
    W1["k8s-worker01"]
    W2["k8s-worker02"]
    W3["k8s-worker03"]

    FLUX["Flux GitOps"]
    LB["MetalLB"]
    LH["Longhorn"]
    DNS["Pi-hole + Unbound"]
    ID["Authentik"]
    TUN["Cloudflare Tunnel"]
  end

  R --- IOTV & MGMTV
  CP --- W1 & W2 & W3
  FLUX --- CP
  LB --- CP
  LH --- W1 & W2 & W3
  DNS --- CP
  ID --- CP
  TUN --- CP
```
