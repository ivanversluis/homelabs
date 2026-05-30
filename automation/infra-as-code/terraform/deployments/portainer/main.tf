module "oidc" {
  source = "../../compositions/oidc-app"

  app_name  = "Portainer"
  app_slug  = "portainer"
  subdomain = "portainer"
  domain    = var.domain

  redirect_uris = ["https://portainer.${var.domain}/"]

  groups       = {}
  entitlements = {}

  vault_path_prefix = "infra"

  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  cloudflare_team_name         = var.cloudflare_team_name
  cf_origin_service            = "https://portainer.portainer.svc.cluster.local:9443"
  cf_create_access_application = false
  cf_manage_tunnel_config      = false
  cf_skip_interstitial         = true
  cf_app_launcher_visible      = true
}
