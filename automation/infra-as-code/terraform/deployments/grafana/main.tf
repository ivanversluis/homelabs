# ─────────────────────────────────────────────────────────────────────────────
# Grafana OIDC Deployment
# ─────────────────────────────────────────────────────────────────────────────
# Use case: Grafana published via the existing Cloudflare Tunnel at grafana.${domain}
# - Creates Authentik OIDC provider + application + entitlements
# - Stores OAUTH_CLIENT_ID/SECRET in Vault at secret/infra/grafana
# - Updates the shared Cloudflare tunnel config with the Grafana published route
# - Creates a Cloudflare Zero Trust Access application bound to that route
# - Creates ESO read policy for the Vault path
# ─────────────────────────────────────────────────────────────────────────────

module "grafana" {
  source = "../../compositions/oidc-app"

  # Application identity
  app_name  = "Grafana"
  app_slug  = "grafana"
  subdomain = "grafana"
  domain    = var.domain

  # Authentik OIDC
  redirect_uris = [
    "https://grafana.${var.domain}/login/generic_oauth",
  ]

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

  # Vault
  vault_path_prefix = "infra"

  # Cloudflare
  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  cloudflare_team_name         = var.cloudflare_team_name
  cf_origin_service            = "http://grafana.observability.svc.cluster.local:3000"
  cf_create_access_application = false
  cf_session_duration          = "24h"
  cf_skip_interstitial         = true
  cf_app_launcher_visible      = true
}
