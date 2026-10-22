# ─────────────────────────────────────────────────────────────────────────────
# Authentik OIDC Resource Module
# Creates: groups, OAuth2 provider, application, application entitlements
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_providers {
    authentik = {
      source = "goauthentik/authentik"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

# ── Data sources ─────────────────────────────────────────────────────────────

data "authentik_flow" "authorization" {
  slug = var.authorization_flow_slug
}

data "authentik_flow" "invalidation" {
  slug = var.invalidation_flow_slug
}

data "authentik_certificate_key_pair" "signing" {
  name = var.signing_key_name
}

data "authentik_property_mapping_provider_scope" "scopes" {
  for_each     = toset(var.scope_mapping_names)
  managed_list = [each.value]
}

# ── Client ID (generated, stable) ───────────────────────────────────────────

resource "random_id" "client_id" {
  byte_length = 20
}

# ── Groups ───────────────────────────────────────────────────────────────────

resource "authentik_group" "groups" {
  for_each     = var.groups
  name         = each.key
  is_superuser = false
}

# ── OAuth2 Provider ──────────────────────────────────────────────────────────

resource "authentik_provider_oauth2" "provider" {
  name               = "Provider for ${var.app_name}"
  authorization_flow = data.authentik_flow.authorization.id
  invalidation_flow  = data.authentik_flow.invalidation.id
  client_id          = random_id.client_id.hex
  client_type        = "confidential"
  signing_key        = data.authentik_certificate_key_pair.signing.id
  property_mappings  = [for s in data.authentik_property_mapping_provider_scope.scopes : s.ids[0]]

  allowed_redirect_uris = [
    for uri in var.redirect_uris : {
      matching_mode = "strict"
      url           = uri
    }
  ]

  access_token_validity = var.access_token_validity
  sub_mode              = var.sub_mode

  lifecycle {
    ignore_changes = [client_secret, client_id, logout_uri]
  }
}

# ── API Patch for Grant Types (Workaround) ───────────────────────────────────
# The authentik_provider_oauth2 resource in v2026.2.0 does not natively support 
# grant_types. We use a local-exec provisioner to patch the provider via the API.
resource "terraform_data" "oauth2_provider_grant_types" {
  count = length(var.grant_types) > 0 ? 1 : 0

  triggers_replace = [
    join(",", var.grant_types)
  ]

  provisioner "local-exec" {
    command = "python3 \"${path.module}/patch-grant-types.py\""
    environment = {
      AUTHENTIK_PROVIDER_ID = tostring(authentik_provider_oauth2.provider.id)
      GRANT_TYPES_JSON      = jsonencode(var.grant_types)
    }
  }

  depends_on = [authentik_provider_oauth2.provider]
}

# ── Application ──────────────────────────────────────────────────────────────

resource "authentik_application" "app" {
  name              = var.app_name
  slug              = var.app_slug
  protocol_provider = authentik_provider_oauth2.provider.id
  meta_launch_url   = var.launch_url
  open_in_new_tab   = true

  lifecycle {
    ignore_changes = [meta_icon]
  }
}

# ── Application Entitlements ─────────────────────────────────────────────────

resource "authentik_application_entitlement" "entitlements" {
  for_each = var.entitlements

  name        = each.key
  application = authentik_application.app.uuid
}
