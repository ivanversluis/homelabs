# ─────────────────────────────────────────────────────────────────────────────
# Outputs — Aggregated from all OIDC deployments
# ─────────────────────────────────────────────────────────────────────────────

output "grafana" {
  value = {
    slug              = module.grafana.authentik_slug
    vault_path        = module.grafana.vault_secret_path
    eso_policy        = module.grafana.vault_eso_policy_name
    cloudflare_origin = module.grafana.cloudflare_origin_service
  }
}

output "headlamp" {
  value = {
    slug              = module.headlamp.authentik_slug
    vault_path        = module.headlamp.vault_secret_path
    eso_policy        = module.headlamp.vault_eso_policy_name
    cloudflare_origin = module.headlamp.cloudflare_origin_service
  }
}

output "openwebui" {
  value = {
    slug              = module.openwebui.authentik_slug
    vault_path        = module.openwebui.vault_secret_path
    eso_policy        = module.openwebui.vault_eso_policy_name
    cloudflare_origin = module.openwebui.cloudflare_origin_service
  }
}

output "semaphoreui" {
  value = {
    slug              = module.semaphoreui.authentik_slug
    vault_path        = module.semaphoreui.vault_secret_path
    eso_policy        = module.semaphoreui.vault_eso_policy_name
    cloudflare_origin = module.semaphoreui.cloudflare_origin_service
  }
}

output "argocd" {
  value = {
    slug              = module.argocd.authentik_slug
    vault_path        = module.argocd.vault_secret_path
    eso_policy        = module.argocd.vault_eso_policy_name
    cloudflare_origin = module.argocd.cloudflare_origin_service
  }
}

output "longhorn" {
  value = {
    slug              = module.longhorn.authentik_slug
    vault_path        = module.longhorn.vault_secret_path
    eso_policy        = module.longhorn.vault_eso_policy_name
    cloudflare_origin = module.longhorn.cloudflare_origin_service
  }
}

output "vault" {
  value = {
    slug              = module.vault.authentik_slug
    vault_path        = module.vault.vault_secret_path
    eso_policy        = module.vault.vault_eso_policy_name
    cloudflare_origin = module.vault.cloudflare_origin_service
  }
}

output "portainer" {
  value = {
    slug              = module.portainer.authentik_slug
    vault_path        = module.portainer.vault_secret_path
    eso_policy        = module.portainer.vault_eso_policy_name
    cloudflare_origin = module.portainer.cloudflare_origin_service
  }
}

output "homebox" {
  value = {
    slug              = module.homebox.authentik_slug
    vault_path        = module.homebox.vault_secret_path
    eso_policy        = module.homebox.vault_eso_policy_name
    cloudflare_origin = module.homebox.cloudflare_origin_service
  }
}

output "homepage" {
  value = {
    slug              = module.homepage.authentik_slug
    vault_path        = module.homepage.vault_secret_path
    eso_policy        = module.homepage.vault_eso_policy_name
    cloudflare_origin = module.homepage.cloudflare_origin_service
  }
}

output "forgejo" {
  value = {
    slug              = module.forgejo.authentik_slug
    vault_path        = module.forgejo.vault_secret_path
    eso_policy        = module.forgejo.vault_eso_policy_name
    cloudflare_origin = module.forgejo.cloudflare_origin_service
  }
}

output "n8n" {
  value = {
    slug              = module.n8n.authentik_slug
    vault_path        = module.n8n.vault_secret_path
    eso_policy        = module.n8n.vault_eso_policy_name
    cloudflare_origin = module.n8n.cloudflare_origin_service
  }
}

output "linkding" {
  value = {
    slug              = module.linkding.authentik_slug
    vault_path        = module.linkding.vault_secret_path
    eso_policy        = module.linkding.vault_eso_policy_name
    cloudflare_origin = module.linkding.cloudflare_origin_service
  }
}

output "termix" {
  value = {
    slug              = module.termix.authentik_slug
    vault_path        = module.termix.vault_secret_path
    eso_policy        = module.termix.vault_eso_policy_name
    cloudflare_origin = module.termix.cloudflare_origin_service
  }
}
