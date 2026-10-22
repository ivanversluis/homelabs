terraform {
  required_providers {
    authentik = {
      source = "goauthentik/authentik"
    }
    cloudflare = {
      source = "cloudflare/cloudflare"
    }
    random = {
      source = "hashicorp/random"
    }
    vault = {
      source = "hashicorp/vault"
    }
  }
}

# ── Authentik OIDC for oauth2-proxy ──────────────────────────────────────────

module "authentik" {
  source = "../../modules/authentik-oidc"

  app_name = "Gatus"
  app_slug = "gatus"

  redirect_uris = ["https://gatus.${var.domain}/oauth2/callback"]
  launch_url    = "https://gatus.${var.domain}"

  groups = {
    "Gatus Users" = "Users allowed to access the Gatus dashboard"
  }

  # Live Authentik leads: the hand-made provider has no entitlements scope or
  # entitlement, uses refresh threshold hours=1 and is not opened in a new tab.
  entitlements = {}
  scope_mapping_names = [
    "goauthentik.io/providers/oauth2/scope-openid",
    "goauthentik.io/providers/oauth2/scope-email",
    "goauthentik.io/providers/oauth2/scope-profile",
  ]
  refresh_token_threshold = "hours=1"
  open_in_new_tab         = false

  # Grant types already live (authorization_code, refresh_token); not managed here.
  grant_types = []

  # The live provider was created in the Authentik UI with explicit consent.
  # Pinned to keep behaviour unchanged when adopting it; switch to the module
  # default (implicit consent) deliberately if the consent screen is not wanted.
  authorization_flow_slug = "default-provider-authorization-explicit-consent"
}

# ── DNS CNAME for gatus.domain ───────────────────────────────────────────────

resource "cloudflare_dns_record" "gatus_cname" {
  zone_id = var.cloudflare_zone_id
  name    = "gatus"
  type    = "CNAME"
  content = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# ── Cloudflare Access service token (optional) ───────────────────────────────

resource "cloudflare_zero_trust_access_service_token" "gatus" {
  count = var.create_cloudflare_access_service_token ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "gatus-homelab-monitor"
  duration   = var.cloudflare_access_service_token_duration
}

resource "cloudflare_zero_trust_access_policy" "allow_gatus_service_token" {
  count = var.create_cloudflare_access_service_token ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "Allow Gatus synthetic checks"
  decision   = "allow"

  include = [{
    service_token = {
      token_id = cloudflare_zero_trust_access_service_token.gatus[0].id
    }
  }]
}

# ── Vault secret and ESO policy ──────────────────────────────────────────────

resource "vault_generic_secret" "gatus" {
  path = "secret/infra/gatus"

  data_json = jsonencode({
    DISCORD_WEBHOOK_URL     = var.gatus_discord_webhook_url
    PORTAINER_MONITOR_TOKEN = var.gatus_portainer_monitor_token
    GITLAB_MONITOR_TOKEN    = var.gatus_gitlab_monitor_token
    OAUTH_CLIENT_ID         = module.authentik.client_id
    OAUTH_CLIENT_SECRET     = module.authentik.client_secret
  })

  disable_read = true

  # Live Vault leads: OAUTH2_PROXY_COOKIE_SECRET (and legacy CF_ACCESS_* keys)
  # are maintained in Vault itself; never rewrite the whole secret from here.
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_policy" "eso_read_gatus" {
  name = "eso-read-infra-gatus"

  policy = <<-EOT
    path "secret/data/infra/gatus" {
      capabilities = ["read"]
    }

    path "secret/metadata/infra/gatus" {
      capabilities = ["read", "list"]
    }
  EOT
}
