terraform {
  # State was last written by Terraform 1.15.x; older binaries refuse to read it.
  required_version = ">= 1.15.2"

  # Runs from Semaphore UI: state lives on the semaphoreui-terraform-state PVC
  # (infra/semaphoreui). For local validation use `terraform init -backend=false`.
  # See docs/lifecycle/terraform-semaphore-migration.md.
  backend "local" {
    path = "/var/lib/terraform-state/homelab/terraform.tfstate"
  }

  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2026.2"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}
