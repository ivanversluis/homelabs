output "authentik_application_slug" {
  description = "Authentik application slug (used in OIDC discovery URL)"
  value       = module.oidc.authentik_slug
}

output "vault_path" {
  description = "Vault path where OIDC credentials are stored"
  value       = module.oidc.vault_secret_path
}

output "vault_eso_policy_name" {
  description = "Vault policy name for ESO read access"
  value       = module.oidc.vault_eso_policy_name
}
