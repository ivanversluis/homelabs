variable "cloudflare_account_id" {
  description = "Cloudflare account ID"
  type        = string
  sensitive   = true
}

variable "cloudflare_team_name" {
  description = "Cloudflare Zero Trust team name"
  type        = string
  sensitive   = true
}

variable "gatus_discord_webhook_url" {
  description = "Optional Discord webhook URL for Gatus notifications"
  type        = string
  sensitive   = true
  default     = ""
}

variable "gatus_portainer_monitor_token" {
  description = "Portainer API key for Gatus monitoring checks (x-api-key header)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "gatus_gitlab_monitor_token" {
  description = "GitLab personal access token for Gatus monitoring checks (PRIVATE-TOKEN header)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "create_cloudflare_access_service_token" {
  description = "Create a Cloudflare Access service token for Gatus synthetic checks"
  type        = bool
  default     = false
}

variable "cloudflare_access_service_token_duration" {
  description = "Validity duration for the Gatus Cloudflare Access service token"
  type        = string
  default     = "8760h"
}
