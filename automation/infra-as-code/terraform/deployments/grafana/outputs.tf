output "authentik_slug" {
  description = "Authentik application slug for OIDC discovery URL"
  value       = module.grafana.authentik_slug
}

output "vault_secret_path" {
  description = "Vault path where OIDC credentials are stored"
  value       = module.grafana.vault_secret_path
}

output "vault_eso_policy_name" {
  description = "Vault policy name to attach to ESO kubernetes auth role"
  value       = module.grafana.vault_eso_policy_name
}

output "cloudflare_app_id" {
  description = "Cloudflare Access application ID"
  value       = module.grafana.cloudflare_app_id
}

output "cloudflare_hostname" {
  description = "Cloudflare published hostname"
  value       = module.grafana.cloudflare_hostname
  sensitive   = true
}

output "cloudflare_origin_service" {
  description = "Origin service configured in the tunnel route"
  value       = module.grafana.cloudflare_origin_service
}

output "oidc_discovery_url" {
  description = "OIDC discovery URL for the application"
  value       = "https://auth.${var.domain}/application/o/${module.grafana.authentik_slug}/.well-known/openid-configuration"
  sensitive   = true
}
