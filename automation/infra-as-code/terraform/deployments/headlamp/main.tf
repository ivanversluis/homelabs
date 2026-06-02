module "oidc" {
  source = "../../compositions/oidc-app"

  app_name  = "Headlamp"
  app_slug  = "headlamp"
  subdomain = "headlamp"
  domain    = var.domain

  redirect_uris = [
    "https://headlamp.${var.domain}/oidc/callback",
    "https://k8s.${var.domain}/oidc/callback",
  ]

  groups = {
    "Headlamp Admins"  = "Full cluster-admin access via Headlamp"
    "Headlamp Viewers" = "Read-only cluster access via Headlamp"
  }
  entitlements = {
    "Headlamp Admins"  = "Maps to cluster-admin ClusterRole"
    "Headlamp Viewers" = "Maps to view ClusterRole"
  }

  vault_path_prefix = "infra"
  extra_vault_data = {
    "idp-issuer-url"    = "https://auth.${var.domain}/application/o/headlamp/"
    "oidc-callback-url" = "https://headlamp.${var.domain}/oidc/callback"
  }

  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  cloudflare_team_name         = var.cloudflare_team_name
  cf_origin_service            = "http://headlamp.headlamp.svc.cluster.local"
  cf_create_access_application = false
  cf_manage_tunnel_config      = false
  cf_skip_interstitial         = true
  cf_app_launcher_visible      = true
}
