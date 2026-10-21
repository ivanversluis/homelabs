# Vault policy "terraform-semaphore": used by Terraform runs in Semaphore UI
# (Kubernetes-auth role "terraform-semaphore", bound to the semaphore-ansible
# service account in namespace semaphoreui).
# See docs/lifecycle/terraform-semaphore-migration.md.

# App secrets written by the oidc-app / vault-app-secret modules.
path "secret/data/infra/*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "secret/data/apps/*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "secret/metadata/infra/*" {
  capabilities = ["read", "list", "delete"]
}
path "secret/metadata/apps/*" {
  capabilities = ["read", "list", "delete"]
}

# Terraform's own inputs (read by ESO, never by Terraform).
path "secret/data/infra/terraform" {
  capabilities = ["deny"]
}
path "secret/metadata/infra/terraform" {
  capabilities = ["deny"]
}

# FAIL-CLOSED GUARD. These paths also hold keys Terraform does not manage
# (admin credentials, encryption keys, DB passwords, repo credentials, ...).
# vault_generic_secret rewrites the WHOLE secret, which would wipe them. Remove
# a path from this list only after the vault-app-secret module preserves
# foreign keys (follow-up PR).
path "secret/data/infra/semaphoreui" {
  capabilities = ["deny"]
}
path "secret/data/infra/argocd" {
  capabilities = ["deny"]
}
path "secret/data/infra/openwebui" {
  capabilities = ["deny"]
}
path "secret/data/apps/forgejo" {
  capabilities = ["deny"]
}
path "secret/data/apps/n8n" {
  capabilities = ["deny"]
}
path "secret/data/apps/vaultwarden" {
  capabilities = ["deny"]
}

# ESO read policies managed by the modules (eso-read-<path>).
path "sys/policies/acl/eso-read-*" {
  capabilities = ["create", "read", "update", "delete"]
}

# Lets the Vault provider detect the KV v2 mount.
path "sys/internal/ui/mounts/secret/*" {
  capabilities = ["read"]
}
