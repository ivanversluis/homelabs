# Vault policy "external-secrets-terraform-inputs": lets External Secrets Operator
# read the Terraform inputs for Semaphore (secret/infra/terraform).
# Deliberately NOT named eso-read-*: the terraform-semaphore policy may write
# policies with that prefix and must not be able to widen ESO's access.
path "secret/data/infra/terraform" {
  capabilities = ["read"]
}
path "secret/metadata/infra/terraform" {
  capabilities = ["read", "list"]
}
