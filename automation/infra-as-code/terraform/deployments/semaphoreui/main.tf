module "oidc" {
  source = "../../compositions/oidc-app"

  app_name  = "SemaphoreUI"
  app_slug  = "semaphoreui"
  subdomain = "demo-semaphore"
  domain    = var.domain

  redirect_uris = ["https://demo-semaphore.${var.domain}/api/auth/oidc/redirect"]

  groups = {
    "Semaphore Admins" = "SemaphoreUI administrators with full access"
    "Semaphore Users"  = "SemaphoreUI users who can run tasks"
  }
  entitlements = {
    "Semaphore Admins" = "Maps to Semaphore admin role"
    "Semaphore Users"  = "Maps to Semaphore user role"
  }

  vault_path_prefix = "infra"

  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  cloudflare_team_name         = var.cloudflare_team_name
  cf_origin_service            = "http://semaphoreui.semaphoreui.svc.cluster.local:3000"
  cf_create_access_application = false
  cf_manage_tunnel_config      = false
  cf_skip_interstitial         = true
  cf_app_launcher_visible      = true
}
