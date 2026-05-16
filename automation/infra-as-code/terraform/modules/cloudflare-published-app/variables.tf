variable "account_id" {
  description = "Cloudflare account ID"
  type        = string
  sensitive   = true
}

variable "tunnel_id" {
  description = "Existing Cloudflare Tunnel UUID that owns the published application routes"
  type        = string
  sensitive   = true
}

variable "app_name" {
  description = "Display name of the application"
  type        = string
}

variable "app_domain" {
  description = "Public hostname published by the tunnel (e.g., grafana.example.com)"
  type        = string
}

variable "origin_service" {
  description = "Origin service URL used by the tunnel (e.g., http://grafana.observability.svc.cluster.local:3000)"
  type        = string
}

variable "team_name" {
  description = "Cloudflare Zero Trust team name used for Access JWT validation at the tunnel"
  type        = string
  default     = ""
}

variable "create_access_application" {
  description = "Whether to create a Zero Trust Access application and bind its AUD tag to the tunnel route"
  type        = bool
  default     = true
}

variable "session_duration" {
  description = "Access application session duration"
  type        = string
  default     = "24h"
}

variable "auto_redirect_to_identity" {
  description = "Automatically redirect users to the identity provider"
  type        = bool
  default     = false
}

variable "skip_interstitial" {
  description = "Skip the Access interstitial page"
  type        = bool
  default     = true
}

variable "app_launcher_visible" {
  description = "Show application in the Access app launcher"
  type        = bool
  default     = true
}

variable "logo_url" {
  description = "Optional logo URL for the Access application"
  type        = string
  default     = null
}

variable "allowed_idps" {
  description = "Optional list of allowed Cloudflare identity provider IDs"
  type        = list(string)
  default     = []
}

variable "policy_ids" {
  description = "List of existing Cloudflare Access policy UUIDs to attach to this application (in order of precedence)"
  type        = list(string)
  default     = []
}

variable "http_host_header" {
  description = "Optional Host header override sent to the origin service"
  type        = string
  default     = ""
}

variable "fallback_service" {
  description = "Catch-all ingress service that remains last in the tunnel config"
  type        = string
  default     = "http_status:404"
}
