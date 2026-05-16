output "authentik_client_id" {
  description = "OAuth2 client ID (sensitive)"
  value       = module.authentik.client_id
  sensitive   = true
}

output "authentik_client_secret" {
  description = "OAuth2 client secret (sensitive)"
  value       = module.authentik.client_secret
  sensitive   = true
}

output "authentik_slug" {
  description = "Authentik application slug"
  value       = module.authentik.application_slug
}

output "vault_secret_path" {
  description = "Vault path where OIDC credentials are stored"
  value       = module.vault.secret_path
}

output "vault_eso_policy_name" {
  description = "Vault policy name for ESO read access"
  value       = module.vault.policy_name
}

output "cloudflare_app_id" {
  description = "Cloudflare Access application ID"
  value       = module.cloudflare.access_app_id
}

output "cloudflare_app_aud" {
  description = "Cloudflare Access application AUD tag"
  value       = module.cloudflare.access_app_aud
}

output "cloudflare_hostname" {
  description = "Published hostname managed in the Cloudflare tunnel config"
  value       = module.cloudflare.hostname
}

output "cloudflare_origin_service" {
  description = "Origin service URL configured in the Cloudflare tunnel config"
  value       = module.cloudflare.origin_service
}
