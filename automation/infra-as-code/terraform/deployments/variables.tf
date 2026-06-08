# ─────────────────────────────────────────────────────────────────────────────
# Shared Variables — All OIDC Deployments
# ─────────────────────────────────────────────────────────────────────────────
# These are provided via terraform.tfvars (gitignored) or TF_VAR_* env vars.
# ─────────────────────────────────────────────────────────────────────────────

variable "domain" {
  description = "Base domain (sensitive, not committed to git)"
  type        = string
  sensitive   = true
}

variable "authentik_url" {
  description = "Authentik API URL (e.g., https://auth.example.com)"
  type        = string
  sensitive   = true
}

variable "authentik_token" {
  description = "Authentik API token"
  type        = string
  sensitive   = true
}

variable "vault_address" {
  description = "Vault server address (e.g., https://vault.example.com)"
  type        = string
  sensitive   = true
}

variable "vault_token" {
  description = "Vault authentication token"
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Access:Edit permissions"
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID"
  type        = string
  sensitive   = true
}

variable "cloudflare_tunnel_id" {
  description = "Existing Cloudflare Tunnel UUID for published application routes"
  type        = string
  sensitive   = true
}

variable "cloudflare_team_name" {
  description = "Cloudflare Zero Trust team name"
  type        = string
  sensitive   = true
}

variable "vault_prometheus_metrics_token" {
  description = "Existing Vault prometheus metrics token stored in infra/vault secret (sensitive, from tfvars)"
  type        = string
  sensitive   = true
}

variable "gatus_discord_webhook_url" {
  description = "Optional Discord webhook URL for Gatus notifications. Leave empty to disable Discord until ready."
  type        = string
  sensitive   = true
  default     = ""
}

variable "gatus_portainer_monitor_token" {
  description = "Portainer API key for Gatus monitoring checks (x-api-key header)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "gatus_gitlab_monitor_token" {
  description = "GitLab personal access token for Gatus monitoring checks (PRIVATE-TOKEN header)."
  type        = string
  sensitive   = true
  default     = ""
}
