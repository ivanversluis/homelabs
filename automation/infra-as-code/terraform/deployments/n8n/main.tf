module "oidc" {
  source = "../../compositions/oidc-app"

  app_name  = "N8N"
  app_slug  = "n8n"
  subdomain = "n8n"
  domain    = var.domain

  redirect_uris = ["https://n8n.${var.domain}/rest/oauth2-credential/callback"]

  groups       = {}
  entitlements = {}

  vault_path_prefix = "apps"

  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  cloudflare_team_name         = var.cloudflare_team_name
  cf_origin_service            = "http://n8n.n8n.svc.cluster.local:5678"
  cf_create_access_application = false
  cf_manage_tunnel_config      = false
  cf_skip_interstitial         = true
  cf_app_launcher_visible      = true
}
