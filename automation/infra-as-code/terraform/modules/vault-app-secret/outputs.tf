output "secret_path" {
  description = "Full Vault path where the secret is stored"
  value       = vault_generic_secret.app_secret.path
}

output "policy_name" {
  description = "Name of the Vault policy granting ESO read access"
  value       = vault_policy.eso_read.name
}
