# OASM uses the shared OIDC composition, not its own Terraform resources.
# Tunnel is owned centrally by deployments/tunnel.tf.
module "oidc" {
  source = "../../compositions/oidc-app"
  app_name  = "Open ASM"
  app_slug  = "oasm"
  subdomain = "oasm"
  domain    = var.domain
  redirect_uris = ["https://oasm.${var.domain}/oauth2/callback"]
  groups = {
    "OASM Users" = "Authorized Open ASM UI users"
  }
  entitlements = {}
  vault_path_prefix = "apps"
  # This creates only the OIDC client credentials; other runtime keys are
  # created and maintained manually in Vault, not by Terraform.
  cloudflare_account_id = var.cloudflare_account_id
  cloudflare_tunnel_id  = var.cloudflare_tunnel_id
  cloudflare_team_name  = var.cloudflare_team_name
  cf_origin_service = "http://kong-kong-proxy.kong.svc.cluster.local:80"
  cf_create_access_application = false
  cf_manage_tunnel_config = false
}
