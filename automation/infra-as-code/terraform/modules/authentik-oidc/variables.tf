variable "app_name" {
  description = "Name of the application in Authentik"
  type        = string
}

variable "app_slug" {
  description = "URL slug for the Authentik application (used in OIDC discovery URL)"
  type        = string
}

variable "redirect_uris" {
  description = "List of allowed redirect URIs (must be exact match)"
  type        = list(string)
}

variable "launch_url" {
  description = "Launch URL shown in the Authentik application list"
  type        = string
}

variable "groups" {
  description = "Map of group names to create (value is description)"
  type        = map(string)
  default     = {}
}

variable "entitlements" {
  description = "Map of application entitlement names (value is description)"
  type        = map(string)
  default     = {}
}

variable "scope_mapping_names" {
  description = "List of Authentik managed scope mapping names to attach"
  type        = list(string)
  default = [
    "goauthentik.io/providers/oauth2/scope-openid",
    "goauthentik.io/providers/oauth2/scope-email",
    "goauthentik.io/providers/oauth2/scope-profile",
    "goauthentik.io/providers/oauth2/scope-entitlements",
  ]
}

variable "authorization_flow_slug" {
  description = "Slug of the authorization flow to use"
  type        = string
  default     = "default-provider-authorization-implicit-consent"
}

variable "invalidation_flow_slug" {
  description = "Slug of the invalidation flow (used for logout/session end)"
  type        = string
  default     = "default-provider-invalidation-flow"
}

variable "signing_key_name" {
  description = "Name of the certificate key pair used for signing tokens"
  type        = string
  default     = "authentik Self-signed Certificate"
}

variable "access_token_validity" {
  description = "Access token validity duration"
  type        = string
  default     = "minutes=5"
}
variable "grant_types" {
  description = "OAuth2 grant types supported by the provider (bypasses terraform provider limitation via API patch)"
  type        = list(string)
  default     = ["authorization_code", "refresh_token"]
}

variable "redirect_uri_type" {
  description = "Type of each allowed redirect URI (Authentik 2026.8 provider attribute). Live providers use \"authorization\"."
  type        = string
  default     = "authorization"
}

variable "open_in_new_tab" {
  description = "Open the application in a new browser tab from the Authentik library"
  type        = bool
  default     = true
}

variable "refresh_token_threshold" {
  description = "Refresh token threshold. null keeps the provider default (seconds=0)."
  type        = string
  default     = null
}

variable "sub_mode" {
  description = "OIDC sub claim mode. Options: hashed_user_id (default, privacy-preserving), user_username, user_email, user_id, user_uuid. Use user_username when the app links accounts by username (e.g. Forgejo)."
  type        = string
  default     = "hashed_user_id"
}
