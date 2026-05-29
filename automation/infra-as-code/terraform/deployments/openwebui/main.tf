module "oidc" {
  source = "../../compositions/oidc-app"

  app_name  = "Open WebUI"
  app_slug  = "openwebui"
  subdomain = "ai-chat"
  domain    = var.domain

  redirect_uris = ["https://ai-chat.${var.domain}/oauth/oidc/callback"]

  groups       = {}
  entitlements = {}

  vault_path_prefix = "infra"
  extra_vault_data = {
    "ENABLE_LOGIN_FORM"             = "false"
    "ENABLE_OAUTH_SIGNUP"           = "true"
    "OAUTH_MERGE_ACCOUNTS_BY_EMAIL" = "true"
    "OAUTH_PROVIDER_NAME"           = "authentik"
    "OPENID_PROVIDER_URL"           = "https://auth.${var.domain}/application/o/openwebui/.well-known/openid-configuration"
    "OPENID_REDIRECT_URI"           = "https://ai-chat.${var.domain}/oauth/oidc/callback"
    "DEFAULT_USER_ROLE"             = "user"
    "WEBUI_URL"                     = "https://ai-chat.${var.domain}"
  }

  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  cloudflare_team_name         = var.cloudflare_team_name
  cf_origin_service            = "http://openwebui.ai.svc.cluster.local:8080"
  cf_create_access_application = false
  cf_manage_tunnel_config      = false
  cf_skip_interstitial         = true
  cf_app_launcher_visible      = true
}
