module "oidc" {
  source = "../../compositions/oidc-app"

  app_name  = "ArgoCD"
  app_slug  = "argocd"
  subdomain = "demo-argocd"
  domain    = var.domain

  redirect_uris = ["https://demo-argocd.${var.domain}/auth/callback"]

  groups = {
    "ArgoCD Admins"  = "ArgoCD administrators with full cluster management"
    "ArgoCD Viewers" = "ArgoCD viewers with read-only access"
  }
  entitlements = {
    "ArgoCD Admins"  = "Maps to ArgoCD role:admin"
    "ArgoCD Viewers" = "Maps to ArgoCD role:readonly"
  }

  vault_path_prefix = "infra"

  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  cloudflare_team_name         = var.cloudflare_team_name
  cf_origin_service            = "http://argocd-server.argocd.svc.cluster.local:80"
  cf_create_access_application = false
  cf_manage_tunnel_config      = false
  cf_skip_interstitial         = true
  cf_app_launcher_visible      = true
}
