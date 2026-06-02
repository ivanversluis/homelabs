module "oidc" {
  source = "../../compositions/oidc-app"

  app_name  = "Longhorn"
  app_slug  = "longhorn"
  subdomain = "storage"
  domain    = var.domain

  redirect_uris = ["https://storage.${var.domain}/oauth2/callback"]

  groups = {
    "Longhorn Admins" = "Users allowed to access Longhorn storage dashboard"
  }
  entitlements = {
    "Longhorn Admins" = "Grants access to Longhorn UI via Kong OIDC proxy"
  }

  vault_path_prefix = "infra"

  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  cloudflare_team_name         = var.cloudflare_team_name
  cf_origin_service            = "http://kong-kong-proxy.kong.svc.cluster.local:80"
  grant_types                  = ["authorization_code", "refresh_token"]

  cf_create_access_application = true
  cf_manage_tunnel_config      = false
  cf_skip_interstitial         = true
  cf_app_launcher_visible      = true
}
