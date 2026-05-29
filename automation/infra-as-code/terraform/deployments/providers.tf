provider "authentik" {
  url   = var.authentik_url
  token = var.authentik_token
}

provider "vault" {
  address = var.vault_address
  token   = var.vault_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
