terraform {
  required_providers {
    cloudflare = {
      source = "cloudflare/cloudflare"
    }
    vault = {
      source = "hashicorp/vault"
    }
  }
}

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

resource "vault_generic_secret" "gatus" {
  path = "secret/infra/gatus"

  data_json = jsonencode({
    DISCORD_WEBHOOK_URL     = var.gatus_discord_webhook_url
    CF_ACCESS_CLIENT_ID     = var.create_cloudflare_access_service_token ? cloudflare_zero_trust_access_service_token.gatus[0].client_id : ""
    CF_ACCESS_CLIENT_SECRET = var.create_cloudflare_access_service_token ? cloudflare_zero_trust_access_service_token.gatus[0].client_secret : ""
    PORTAINER_MONITOR_TOKEN = var.gatus_portainer_monitor_token
    GITLAB_MONITOR_TOKEN    = var.gatus_gitlab_monitor_token
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
