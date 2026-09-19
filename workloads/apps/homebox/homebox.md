# Homebox Homelab wiki

## Documentation
https://homebox.software/en/

## Repo
https://github.com/sysadminsmedia/homebox

## Releases
https://ghcr.io/sysadminsmedia/homebox

## Current version
0.26.2

## Objective
As home-admin I want a self-hosted home inventory management system to track and organize household items, their locations, and maintenance schedules.

## Implementation
Deployed as a Kubernetes Deployment with persistent storage and OIDC authentication via Authentik.

## Stack
Kubernetes Deployment (Kustomize via Flux)

## LLD
- Namespace: homebox
- Image: `ghcr.io/sysadminsmedia/homebox:0.26.2`
- Image policy: `IfNotPresent`; the workload is version-pinned so a pod reschedule cannot become an implicit application upgrade
- Port: tcp/7745
- Volume: PVC mounted at `/data` (Longhorn)
- Security: `runAsUser: 65532`, `runAsNonRoot: true`
- OIDC credentials: `homebox-oidc` Secret synchronized from Vault by External Secrets Operator
- API-key pepper: `homebox-api-key-pepper` Secret generated once by External Secrets Operator and kept immutable; injected as `HBOX_AUTH_API_KEY_PEPPER`
- Authentik is the OIDC identity provider

## Upgrade note
Homebox 0.26.x requires `HBOX_AUTH_API_KEY_PEPPER` to contain at least 32 bytes. The pepper must remain stable because rotating it invalidates issued Homebox API keys. The cluster therefore generates it once instead of regenerating it on every reconcile.

## Lesson learned: do not use `latest` for stateful workloads
During the Wave 3 worker-drain canary, Homebox was evicted from `k8s-worker02`. The previous manifest used `ghcr.io/sysadminsmedia/homebox:latest` together with `imagePullPolicy: Always`, so normal rescheduling pulled a newer application image. That release introduced a required environment variable and Homebox entered `CrashLoopBackOff` even though the maintenance action itself was healthy.

A node drain, reboot, scheduler move, or pod recreation must not silently change the application version. Stateful and operationally important workloads should therefore use an explicit tested image version (and, where practical, an immutable digest). Application upgrades remain a separate GitOps change with their own validation.
