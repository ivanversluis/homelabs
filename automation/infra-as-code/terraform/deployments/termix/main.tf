module "oidc" {
  source = "../../compositions/oidc-app"

  app_name  = "Termix"
  app_slug  = "termix"
  subdomain = "demo-termix"
  domain    = var.domain

  redirect_uris = ["https://demo-termix.${var.domain}/users/oidc/callback"]

  groups       = {}
  entitlements = {}

  vault_path_prefix = "apps"

  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  cloudflare_team_name         = var.cloudflare_team_name
  cf_origin_service            = "http://termix.termix.svc.cluster.local:3000"
  cf_create_access_application = false
  cf_manage_tunnel_config      = false
  cf_skip_interstitial         = true
  cf_app_launcher_visible      = true
}
