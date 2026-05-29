module "oidc" {
  source = "../../compositions/oidc-app"

  app_name  = "Grafana"
  app_slug  = "grafana"
  subdomain = "grafana"
  domain    = var.domain

  redirect_uris = ["https://grafana.${var.domain}/login/generic_oauth"]

  groups = {
    "Grafana Admins"  = "Grafana administrators with full access"
    "Grafana Editors" = "Grafana editors who can modify dashboards"
    "Grafana Viewers" = "Grafana viewers with read-only access"
  }
  entitlements = {
    "Grafana Admins"  = "Maps to Grafana Admin role"
    "Grafana Editors" = "Maps to Grafana Editor role"
    "Grafana Viewers" = "Maps to Grafana Viewer role"
  }

  vault_path_prefix = "infra"

  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  cloudflare_team_name         = var.cloudflare_team_name
  cf_origin_service            = "http://grafana.observability.svc.cluster.local:3000"
  cf_create_access_application = false
  cf_manage_tunnel_config      = false
  cf_skip_interstitial         = true
  cf_app_launcher_visible      = true
}
