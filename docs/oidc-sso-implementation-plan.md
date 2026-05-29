# OIDC SSO Implementation Plan

## Assessment Summary

### Already Implemented (OIDC Working + Network Policies)

| App | Namespace | Vault Path | Redirect URI | RBAC | Terraform |
|-----|-----------|-----------|--------------|------|-----------|
| Grafana | observability | `infra/grafana` | `https://grafana.$DOMAIN/login/generic_oauth` | Yes (Admin/Editor/Viewer via entitlements) | **Done** |
| Homebox | homebox | `apps/homebox` | `https://homebox.$DOMAIN/api/v1/users/login/oidc/callback` | No (single-user) | **Needed** |
| Headlamp | headlamp | `infra/headlamp` | `https://k8s.$DOMAIN/oidc/callback` | Yes (K8s RBAC via groups) | **Needed** |
| Open WebUI | ai | `infra/openwebui` | `https://ai-chat.$DOMAIN/oauth/oidc/callback` | Partial (DEFAULT_USER_ROLE) | **Needed** |
| Homepage | homepage | `apps/homepage` | `https://homepage.$DOMAIN/api/auth/callback/authentik` | No (dashboard) | **Needed** |

### To Implement (Native OIDC Support Available)

| App | Namespace | Vault Path | Redirect URI | RBAC | Notes |
|-----|-----------|-----------|--------------|------|-------|
| Forgejo | forgejo | `apps/forgejo` | `https://forgejo.$DOMAIN/user/oauth2/authentik/callback` | Yes (Admin/User via groups) | Native OAuth2 source via env/API |
| N8N | n8n | `apps/n8n` | `https://n8n.$DOMAIN/rest/oauth2-credential/callback` | No (single-owner workflow) | SSO via env vars since v1.x |
| SemaphoreUI | semaphoreui | `infra/semaphoreui` | `https://demo-semaphore.$DOMAIN/api/auth/oidc/redirect` | Yes (Admin/User teams) | Helm values for OIDC |
| ArgoCD | argocd | `infra/argocd` | `https://demo-argocd.$DOMAIN/auth/callback` | Yes (Admin/ReadOnly via groups) | Helm values `configs.cm` |
| Linkding | linkding | `apps/linkding` | `https://bookmarks.$DOMAIN/oidc/callback/` | No (single-user) | `LD_ENABLE_OIDC=True` since v1.31+ |

### Kong OIDC Proxy (No Native Auth)

| App | Namespace | Subdomain | Service Port | Notes |
|-----|-----------|-----------|-------------|-------|
| Longhorn | longhorn-system | `storage.$DOMAIN` | 8000 (frontend) | Kong OIDC plugin on route |

### Not Applicable

| App | Reason |
|-----|--------|
| Termix | Web terminal — no OIDC support; protected by Cloudflare Access |
| OpenClaw | Internal K8s agent — not user-facing |
| Portainer | Docker Compose stack only (not K8s managed) |
| Vault | OIDC configured via `vault write` CLI (server-side, not env vars) — already done |

## Execution Plan

### Phase 1: Terraform Deployments for Already-Working OIDC Apps

These apps already have OIDC working manually. Terraform will take over IdP-side management.

1. **Homebox** — Create `deployments/homebox/main.tf`
2. **Headlamp** — Create `deployments/headlamp/main.tf`
3. **Open WebUI** — Create `deployments/openwebui/main.tf`
4. **Homepage** — Create `deployments/homepage/main.tf`

### Phase 2: New OIDC Implementations

5. **Forgejo** — Terraform + K8s manifest updates (add OIDC env vars + ExternalSecret)
6. **N8N** — Terraform + K8s manifest updates (replace basic auth with OIDC)
7. **SemaphoreUI** — Terraform + HelmRelease values update
8. **ArgoCD** — Terraform + HelmRelease values update
9. **Linkding** — Terraform + K8s manifest updates (add OIDC env vars)

### Phase 3: Kong OIDC Proxy

10. **Longhorn** — Kong Ingress + OIDC plugin + Terraform for Authentik provider

### Phase 4: Network Policies (Zero Trust)

Add `allow-egress-to-kong` policy to all namespaces that need OIDC egress:
- forgejo (new)
- n8n (new)
- semaphoreui (new)
- argocd (new)
- linkding (new)

Already have egress policies: homebox, headlamp, ai, observability, homepage

### Phase 5: Validation & Testing

- Verify ExternalSecret sync for all apps
- Test OIDC discovery URL from inside each pod
- Confirm redirect URI works
- Validate RBAC role mapping where applicable
