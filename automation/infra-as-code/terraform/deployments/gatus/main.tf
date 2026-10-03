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

resource "random_password" "oauth2_proxy_cookie_secret" {
  length  = 32
  special = false
}

module "authentik" {
  source = "../../modules/authentik-oidc"

  app_name = "Gatus"
  app_slug = "gatus"

  redirect_uris = ["https://gatus.${var.domain}/oauth2/callback"]
  launch_url    = "https://gatus.${var.domain}"

  groups = {
    "Gatus Users" = "Users allowed to access the Gatus dashboard"
  }

  entitlements = {
    "Gatus Users" = "Grants access to Gatus via oauth2-proxy"
  }

  grant_types = ["authorization_code", "refresh_token"]
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
    DISCORD_WEBHOOK_URL        = var.gatus_discord_webhook_url
    PORTAINER_MONITOR_TOKEN    = var.gatus_portainer_monitor_token
    GITLAB_MONITOR_TOKEN       = var.gatus_gitlab_monitor_token
    OAUTH_CLIENT_ID            = module.authentik.client_id
    OAUTH_CLIENT_SECRET        = module.authentik.client_secret
    OAUTH2_PROXY_COOKIE_SECRET = random_password.oauth2_proxy_cookie_secret.result
  })

  disable_read = true
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
