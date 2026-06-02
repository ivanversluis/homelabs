# ─────────────────────────────────────────────────────────────────────────────
# OIDC App Composition Module
# Bundles: Authentik OIDC + Vault secret + Cloudflare published route + Access
# ─────────────────────────────────────────────────────────────────────────────
# This composition wires the three providers together:
#   1. Creates Authentik groups + provider + application + entitlements
#   2. Stores resulting client_id/secret in Vault at the standard path
#   3. Creates or updates the Cloudflare published application route on a tunnel
#   4. Optionally creates a Cloudflare Zero Trust Access application for the domain
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_providers {
    authentik = {
      source = "goauthentik/authentik"
    }
    vault = {
      source = "hashicorp/vault"
    }
    cloudflare = {
      source = "cloudflare/cloudflare"
    }
  }
}

# ── Authentik OIDC ───────────────────────────────────────────────────────────

module "authentik" {
  source = "../../modules/authentik-oidc"

  app_name = var.app_name
  app_slug = var.app_slug
  redirect_uris = [
    for uri in var.redirect_uris : uri
  ]
  launch_url   = "https://${var.subdomain}.${var.domain}"
  groups       = var.groups
  entitlements = var.entitlements

  scope_mapping_names     = var.scope_mapping_names
  authorization_flow_slug = var.authorization_flow_slug
  invalidation_flow_slug  = var.invalidation_flow_slug
  signing_key_name        = var.signing_key_name
  grant_types             = var.grant_types
  access_token_validity   = var.access_token_validity
}

# ── Vault Secret ─────────────────────────────────────────────────────────────

module "vault" {
  source = "../../modules/vault-app-secret"

  vault_path = "${var.vault_path_prefix}/${var.app_slug}"

  secret_data = merge(
    {
      OAUTH_CLIENT_ID     = module.authentik.client_id
      OAUTH_CLIENT_SECRET = module.authentik.client_secret
    },
    var.extra_vault_data
  )
}

# ── Cloudflare Published Route + Access ─────────────────────────────────────

module "cloudflare" {
  source = "../../modules/cloudflare-published-app"

  account_id = var.cloudflare_account_id
  tunnel_id  = var.cloudflare_tunnel_id
  app_name   = var.app_name
  app_domain = "${var.subdomain}.${var.domain}"

  origin_service            = var.cf_origin_service
  team_name                 = var.cloudflare_team_name
  create_access_application = var.cf_create_access_application
  manage_tunnel_config      = var.cf_manage_tunnel_config
  session_duration          = var.cf_session_duration
  auto_redirect_to_identity = var.cf_auto_redirect
  skip_interstitial         = var.cf_skip_interstitial
  app_launcher_visible      = var.cf_app_launcher_visible
  logo_url                  = var.cf_logo_url
  allowed_idps              = var.cf_allowed_idps
  http_host_header          = var.cf_http_host_header
  policy_ids                = var.cf_access_policy_ids
}
