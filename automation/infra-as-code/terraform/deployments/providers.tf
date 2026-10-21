provider "authentik" {
  url   = var.authentik_url
  token = var.authentik_token
}

# Semaphore authenticates with its own Kubernetes service account
# (var.vault_kubernetes_role). A static var.vault_token is only a fallback for
# manual runs.
provider "vault" {
  address          = var.vault_address
  token            = var.vault_token != "" ? var.vault_token : null
  skip_child_token = var.vault_kubernetes_role != "" ? true : null

  dynamic "auth_login" {
    for_each = var.vault_kubernetes_role != "" ? [1] : []
    content {
      path = "auth/${var.vault_kubernetes_mount}/login"
      parameters = {
        role = var.vault_kubernetes_role
        jwt  = file("/var/run/secrets/kubernetes.io/serviceaccount/token")
      }
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
