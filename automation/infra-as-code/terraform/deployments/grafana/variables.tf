# ── Sensitive credentials (from terraform.tfvars — gitignored) ────────────────

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
