output "authentik_slug"           { value = module.oidc.authentik_slug }
output "vault_secret_path"        { value = module.oidc.vault_secret_path }
output "vault_eso_policy_name"    { value = module.oidc.vault_eso_policy_name }
output "cloudflare_origin_service" { value = module.oidc.cloudflare_origin_service }
