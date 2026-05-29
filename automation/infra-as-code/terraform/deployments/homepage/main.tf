module "oidc" {
  source = "../../compositions/oidc-app"

  app_name  = "Homepage"
  app_slug  = "homepage"
  subdomain = "homepage"
  domain    = var.domain

  redirect_uris = ["https://homepage.${var.domain}/api/auth/callback/authentik"]

  groups       = {}
  entitlements = {}

  vault_path_prefix = "apps"

  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  cloudflare_team_name         = var.cloudflare_team_name
  cf_origin_service            = "http://homepage.homepage.svc.cluster.local:3000"
  cf_create_access_application = false
  cf_manage_tunnel_config      = false
  cf_skip_interstitial         = true
  cf_app_launcher_visible      = true
}
