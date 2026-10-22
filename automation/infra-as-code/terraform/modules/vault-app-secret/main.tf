# ─────────────────────────────────────────────────────────────────────────────
# Vault App Secret Resource Module
# Creates: KV secret for OIDC credentials + read policy for ESO
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_providers {
    vault = {
      source = "hashicorp/vault"
    }
  }
}

# ── KV Secret ────────────────────────────────────────────────────────────────

resource "vault_generic_secret" "app_secret" {
  path = "secret/${var.vault_path}"

  data_json = jsonencode(var.secret_data)

  disable_read = true

  # Vault is the source of truth. vault_generic_secret rewrites the whole secret
  # (wiping keys Terraform does not know) and creates a new KV version, so it is
  # only used to create a missing secret, never to update an existing one.
  lifecycle {
    ignore_changes = [data_json]
  }
}

# ── ESO Read Policy ──────────────────────────────────────────────────────────
# Grants read access to the specific secret path for External Secrets Operator

resource "vault_policy" "eso_read" {
  name = "eso-read-${replace(var.vault_path, "/", "-")}"

  policy = <<-EOT
    # Allow ESO to read the secret for ${var.vault_path}
    path "secret/data/${var.vault_path}" {
      capabilities = ["read"]
    }

    path "secret/metadata/${var.vault_path}" {
      capabilities = ["read", "list"]
    }
  EOT
}
