# Open ASM (OASM) — EliteBoxes

Source: https://github.com/oasm-platform/open-asm; initial application images pinned to upstream v0.9.0 (2026-10-22).

## What this deploys

- Dedicated `openasm` namespace and Flux Kustomization.
- Console/nginx, core API, PostgreSQL with pgvector, Redis, RustFS, GeoIP.
- Per-component zero-trust ingress and egress; no Docker socket, privileged container, scanning worker, host networking, or LAN-wide scan privileges.
- Kong ingress `oasm.${DOMAIN}` -> oauth2-proxy -> OASM console -> API/RustFS.
- Authentik OAuth2 client and `OASM Users` group via the shared Terraform composition; Cloudflare Tunnel/DNS, Gatus, Homepage.
- Persistent Longhorn-worker RWO claims (retain on Flux pruning). All internal backends are ClusterIP only.

## REQUIRED before merging / enabling

1. Verify Docker Hub `oasm/oasm-api:v0.9.0` and `oasm/oasm-console:v0.9.0`, PostgreSQL/pgvector, Redis, RustFS image `rustfs/rustfs:1.0.3`, and GeoIP startup compatibility on actual cluster nodes. Pin all external dependencies to trusted digest after verification. GeoIP is intentionally a documented daily-rebuilt mutable-image exception.
2. In Vault's existing `secret/apps/oasm` KV v2 secret, create **random unique** `OASM_CLOUD_APIKEY`, `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `REDIS_URL=redis://:<encoded-password>@oasm-redis:6379/0`, `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY`, `ENCRYPTION_KEYS`, and `OAUTH2_PROXY_COOKIE_SECRET`. Never commit values. `REDIS_URL` must match Redis' requirepass value. Back up `ENCRYPTION_KEYS` securely; losing it loses encrypted integration credentials.
3. Apply Terraform through Semaphore **only after reviewing the plan**. It creates Authentik OIDC credentials at the same Vault path through the `vault-app-secret` composition, whose `ignore_changes=[data_json]` protects existing values on ordinary updates but does not merge arbitrary keys on first creation. **Create the OIDC app first, before adding runtime keys in Vault** so Terraform's initial write does not erase those manually added keys. Then add runtime keys without running a replacement import/taint of the Terraform Vault resource. Confirm ESO can fetch all properties.
4. Generate cookie secret of valid oauth2-proxy length/encoding. Assign real users to **OASM Users** in Authentik; do not grant everyone by default.
5. Confirm `oasm.${DOMAIN}` DNS resolves to the existing tunnel. The tunnel Terraform only adds a missing route, retaining existing rules; inspect all other tunnel changes in the plan for drift. Gatus checks the browser-visible login route, not scanner readiness.
6. Confirm CPU/memory/storage capacity and Longhorn backups. Check the pod security context against upstream image permissions. Restricted PSA remains enforced.

## Important worker limitation

**Scanning is not enabled by this PR.** Upstream 0.9.0 uses Docker Engine to launch connector containers. EliteBoxes Kubernetes uses containerd; a host Docker socket or privileged Docker-in-Docker worker would extend root-equivalent execution to scanner images. Do not add a socket, hostPath, privileged worker or blanket LAN scan egress to the existing cluster. Deploy a separate disposable, isolated Docker VM/host on a scanner VLAN, with a firewall allowlist for only explicitly authorized LAN CIDRs / internet targets, a per-worker callback endpoint (26276) and restricted outbound API gRPC connectivity (16276). Design and verify worker callback routing, Authentik/SSO expectations and workload firewall controls separately before enabling it. Access to the console itself does not authorize scans. Do not scan third-party internet assets without permission.

## Checks

```sh
kubectl kustomize workloads/apps/openasm --load-restrictor=LoadRestrictionsNone
python3 scripts/validate-public-routes.py
python3 scripts/validate-mutable-images.py
kubectl -n openasm get pods,pvc,svc,externalsecret,ingress
flux -n flux-system get kustomizations openasm
```

Health: `GET /api/health` proxied through console (requires Authentik login). Monitor deployment and PVC health separately. No scanner run is expected until a worker is registered.

## Release caveats

This is GitOps deployment code, **not a live deployment verification**. Upstream images and external dependencies were reviewed from published manifests; full image runtime tests, real Vault secret readiness, Cloudflare state, SSO callbacks, PostgreSQL migrations, RustFS compatibility, and live Calico traffic checks must be confirmed before considering this production-ready. In particular the core API currently supports its own email/password accounts: oauth2-proxy protects access to the app, not the application-level accounts. A true Authentik native SSO login in OASM would require upstream OIDC support; proxy login is an additional authentication gate.
