module "oidc" {
  source = "../../compositions/oidc-app"

  app_name  = "Vault"
  app_slug  = "vault"
  subdomain = "demo-vault"
  domain    = var.domain

  redirect_uris = [
    "https://vault.${var.domain}/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback",
  ]

  groups       = {}
  entitlements = {}

  vault_path_prefix = "infra"

  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  cloudflare_team_name         = var.cloudflare_team_name
  cf_origin_service            = "http://vault.vault.svc.cluster.local:8200"
  cf_create_access_application = false
  cf_manage_tunnel_config      = false
  cf_skip_interstitial         = true
  cf_app_launcher_visible      = true
}
