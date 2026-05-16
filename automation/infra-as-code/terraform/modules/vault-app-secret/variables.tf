variable "vault_path" {
  description = "Vault KV path (e.g., 'infra/grafana' or 'apps/homebox')"
  type        = string
}

variable "secret_data" {
  description = "Map of key-value pairs to store in the Vault secret"
  type        = map(string)
  sensitive   = true
}
