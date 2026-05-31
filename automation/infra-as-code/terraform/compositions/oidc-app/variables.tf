# ── Application identity ──────────────────────────────────────────────────────

variable "app_name" {
  description = "Human-readable application name"
  type        = string
}

variable "app_slug" {
  description = "URL slug used in Authentik OIDC paths and Vault path"
  type        = string
}

variable "subdomain" {
  description = "Subdomain for the application (e.g., 'grafana')"
  type        = string
}

variable "domain" {
  description = "Base domain (e.g., 'example.com'). Sensitive — not stored in code."
  type        = string
  sensitive   = true
}

# ── Authentik config ─────────────────────────────────────────────────────────

variable "redirect_uris" {
  description = "OAuth2 redirect URIs (full URLs including scheme)"
  type        = list(string)
}
variable "groups" {
  description = "Map of Authentik group names to create (value = description)"
  type        = map(string)
  default     = {}
}

variable "entitlements" {
  description = "Map of application entitlement names (value = description)"
  type        = map(string)
  default     = {}
}

variable "scope_mapping_names" {
  description = "Authentik managed scope mapping names"
  type        = list(string)
  default = [
    "goauthentik.io/providers/oauth2/scope-openid",
    "goauthentik.io/providers/oauth2/scope-email",
    "goauthentik.io/providers/oauth2/scope-profile",
    "goauthentik.io/providers/oauth2/scope-entitlements",
  ]
}

variable "authorization_flow_slug" {
  description = "Authentik authorization flow slug"
  type        = string
  default     = "default-provider-authorization-implicit-consent"
}

variable "invalidation_flow_slug" {
  description = "Authentik invalidation flow slug (logout/session end)"
  type        = string
  default     = "default-provider-invalidation-flow"
}

variable "signing_key_name" {
  description = "Authentik signing certificate name"
  type        = string
  default     = "authentik Self-signed Certificate"
}

# ── Vault config ─────────────────────────────────────────────────────────────

variable "vault_path_prefix" {
  description = "Vault KV path prefix ('infra' for infra apps, 'apps' for user apps)"
  type        = string
  default     = "infra"
}

variable "extra_vault_data" {
  description = "Additional key-value pairs to store alongside OIDC credentials"
  type        = map(string)
  default     = {}
  sensitive   = true
}

# ── Cloudflare config ────────────────────────────────────────────────────────

variable "cloudflare_account_id" {
  description = "Cloudflare account ID"
  type        = string
  sensitive   = true
}

variable "cloudflare_tunnel_id" {
  description = "Existing Cloudflare Tunnel UUID that owns the published application routes"
  type        = string
  sensitive   = true
}

variable "cloudflare_team_name" {
  description = "Cloudflare Zero Trust team name for Access JWT validation at the tunnel"
  type        = string
  sensitive   = true
}

variable "cf_origin_service" {
  description = "Tunnel origin service URL for the published application"
  type        = string
}

variable "cf_create_access_application" {
  description = "Whether to create a Cloudflare Access application and bind it to the tunnel route"
  type        = bool
  default     = true
}

variable "cf_session_duration" {
  description = "Cloudflare Access session duration"
  type        = string
  default     = "24h"
}

variable "cf_auto_redirect" {
  description = "Auto-redirect to identity provider"
  type        = bool
  default     = false
}

variable "cf_skip_interstitial" {
  description = "Skip the Access interstitial page"
  type        = bool
  default     = true
}

variable "cf_app_launcher_visible" {
  description = "Show in Cloudflare App Launcher"
  type        = bool
  default     = true
}

variable "cf_logo_url" {
  description = "Application logo URL"
  type        = string
  default     = null
}

variable "cf_allowed_idps" {
  description = "List of allowed identity provider IDs in Cloudflare Access"
  type        = list(string)
  default     = []
}

variable "cf_http_host_header" {
  description = "Optional Host header override sent by cloudflared to the origin service"
  type        = string
  default     = ""
}

variable "cf_access_policy_ids" {
  description = "List of existing Cloudflare Access policy UUIDs to attach to the Access application (in precedence order)"
  type        = list(string)
  default     = []
}

variable "cf_manage_tunnel_config" {
  description = "Whether to manage the Cloudflare tunnel config from this module instance. Set to false when using a single root module that manages tunnel config centrally."
  type        = bool
  default     = true
}
variable "grant_types" {
  description = "OAuth2 grant types supported by the provider"
  type        = list(string)
  default     = null
}
