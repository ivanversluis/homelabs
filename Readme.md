My personal bare-metal Kubernetes homelab, managed with Flux GitOps and slowly optimized as an enterprise grade instance. Focus on core services and later on hardening the services and having meaningful observability on top.
## Architecture

```mermaid
---
config:
  layout: dagre
  themeVariables:
    primaryColor: '#0088cc'
    edgeLabelBackground: '#f8f8f8'
    tertiaryColor: '#ffffff'
---
flowchart LR
 subgraph ControlPlane["Control Plane"]
        CP["k8s-master01"]
  end
 subgraph Workers["Worker Nodes"]
    direction LR
        W1["k8s-worker01"]
        W2["k8s-worker02"]
        W3["k8s-worker03"]
  end
 subgraph CoreServices["Storage & Networking Layer"]
    direction LR
        LH["Longhorn - Persistent storage"]
        CL["Calico - CNI"]
        LB["MetalLB - Load Balancer"]
  end
 subgraph Infra["Apps & Infrastructure Services"]
    direction LR
        ID["Authentik (Identity)"]
        DNS["Pi-hole + Unbound (DNS)"]
        VAULT["Vault"]
        TUN["Cloudflare Tunnel"]
  end
 subgraph K8S["Kubernetes Cluster · Arch Linux"]
    direction TB
        ControlPlane
        Workers
        CoreServices
        Infra
  end
 subgraph GitOps["GitOps · Deployment Management"]
    direction TB
        FLUX["Flux CD"]
  end
    CP --> Workers
    Workers --> CoreServices
    FLUX --> CoreServices & Infra
    CoreServices --> Infra
  style CP fill:#0088cc
  style W1 fill:#0088cc
  style W2 fill:#0088cc
  style W3 fill:#0088cc
```

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
| CNI            | Calico                              | Cilium  |
| GitOps         | Flux (Kustomize + HelmRelease)      | —       |
| LB             | MetalLB                             | kube-vip (planned) |
| Storage        | Longhorn                            | —       |
| DNS            | Pi-hole + Unbound                   | —       |
| Secrets        | Vault + External Secrets            | —       |
| Identity       | Authentik                           | —       |
| Tunnel         | Cloudflare Tunnel                   | —       |
| Monitoring     | kube-prometheus-stack + metrics-server | —    |



