# ─────────────────────────────────────────────────────────────────────────────
# Cloudflare Published Application Module
# Creates: published application route on an existing tunnel + optional Access app
# ─────────────────────────────────────────────────────────────────────────────
# Published application routes in the Cloudflare portal are stored as part of
# the tunnel's shared config document. This module reads the existing config,
# replaces the rule for one hostname, and writes the merged config back.
#
# Important: this is safe only when a single Terraform workflow is the source
# of truth for a given tunnel config. Multiple independent states managing the
# same tunnel can still race on last-writer-wins updates.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_providers {
    cloudflare = {
      source = "cloudflare/cloudflare"
    }
  }
}

data "cloudflare_zero_trust_tunnel_cloudflared_config" "existing" {
  count = var.manage_tunnel_config ? 1 : 0

  account_id = var.account_id
  tunnel_id  = var.tunnel_id
}

resource "cloudflare_zero_trust_access_application" "app" {
  count = var.create_access_application ? 1 : 0

  account_id = var.account_id
  name       = var.app_name
  type       = "self_hosted"
  domain     = var.app_domain
  destinations = [{
    type = "public"
    uri  = var.app_domain
  }]
  session_duration           = var.session_duration
  auto_redirect_to_identity  = var.auto_redirect_to_identity
  http_only_cookie_attribute = true
  same_site_cookie_attribute = "lax"
  skip_interstitial          = var.skip_interstitial
  app_launcher_visible       = var.app_launcher_visible
  logo_url                   = var.logo_url != null && var.logo_url != "" ? var.logo_url : null
  allowed_idps               = var.allowed_idps

  policies = length(var.policy_ids) > 0 ? [
    for idx, pid in var.policy_ids : {
      id         = pid
      precedence = idx + 1
    }
  ] : null
}

locals {
  existing_ingress = var.manage_tunnel_config ? try(data.cloudflare_zero_trust_tunnel_cloudflared_config.existing[0].config.ingress, []) : []

  retained_ingress = [
    for rule in local.existing_ingress : rule
    if try(rule.hostname, "") != var.app_domain && try(rule.service, "") != var.fallback_service
  ]

  managed_ingress = merge(
    {
      hostname = var.app_domain
      service  = var.origin_service
    },
    var.create_access_application ? {
      origin_request = {
        access = {
          required  = true
          team_name = var.team_name
          aud_tag   = [cloudflare_zero_trust_access_application.app[0].aud]
        }
      }
    } : {},
    var.http_host_header == "" ? {} : {
      origin_request = merge(
        var.create_access_application ? {
          access = {
            required  = true
            team_name = var.team_name
            aud_tag   = [cloudflare_zero_trust_access_application.app[0].aud]
          }
        } : {},
        {
          http_host_header = var.http_host_header
        }
      )
    }
  )
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "published_apps" {
  count = var.manage_tunnel_config ? 1 : 0

  account_id = var.account_id
  tunnel_id  = var.tunnel_id

  config = {
    ingress = concat(
      local.retained_ingress,
      [local.managed_ingress],
      [{ service = var.fallback_service }]
    )
  }

  lifecycle {
    # Cloudflare tunnel config is a singleton API object — it cannot be
    # destroyed via Terraform once created. Guard against accidental destroy.
    prevent_destroy = true
  }
}
