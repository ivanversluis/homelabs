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
  grant_types                  = ["authorization_code", "refresh_token"]
  scope_mapping_names          = ["goauthentik.io/providers/oauth2/scope-openid", "goauthentik.io/providers/oauth2/scope-email", "goauthentik.io/providers/oauth2/scope-profile", "goauthentik.io/providers/oauth2/scope-offline_access"]

  cf_create_access_application = false
  cf_manage_tunnel_config      = false
  cf_skip_interstitial         = true
  cf_app_launcher_visible      = true
}
