module "oidc" {
  source = "../../compositions/oidc-app"

  app_name  = "Forgejo"
  app_slug  = "forgejo"
  subdomain = "forgejo"
  domain    = var.domain

  redirect_uris = ["https://forgejo.${var.domain}/user/oauth2/authentik/callback"]
  sub_mode      = "user_username"

  groups = {
    "Forgejo Admins" = "Forgejo site administrators"
    "Forgejo Users"  = "Regular Forgejo users"
  }
  entitlements = {
    "Forgejo Admins" = "Maps to Forgejo site admin"
    "Forgejo Users"  = "Maps to regular user access"
  }

  vault_path_prefix = "apps"

  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  cloudflare_team_name         = var.cloudflare_team_name
  cf_origin_service            = "http://forgejo.forgejo.svc.cluster.local:3000"
  grant_types                  = ["authorization_code", "refresh_token"]

  cf_create_access_application = false
  cf_manage_tunnel_config      = false
  cf_skip_interstitial         = true
  cf_app_launcher_visible      = true
}
