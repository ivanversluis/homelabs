module "oidc" {
  source = "../../compositions/oidc-app"

  app_name  = "Vaultwarden"
  app_slug  = "vaultwarden"
  subdomain = "stargate"
  domain    = var.domain

  redirect_uris = [
    "https://stargate.${var.domain}/identity/connect/oidc-signin",
  ]

  groups       = {}
  entitlements = {}

  vault_path_prefix = "apps"

  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  cloudflare_team_name         = var.cloudflare_team_name
  cf_origin_service            = "http://vaultwarden.vaultwarden.svc.cluster.local:80"
  grant_types                  = ["authorization_code", "refresh_token"]

  cf_create_access_application = false
  cf_manage_tunnel_config      = false
  cf_skip_interstitial         = true
  cf_app_launcher_visible      = true
}
