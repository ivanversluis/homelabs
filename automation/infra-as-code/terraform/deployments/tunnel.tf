# ─────────────────────────────────────────────────────────────────────────────
# Cloudflare Tunnel Config (Singleton)
# Manages ALL published application routes in one resource to avoid conflicts.
# ─────────────────────────────────────────────────────────────────────────────

data "cloudflare_zero_trust_tunnel_cloudflared_config" "existing" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.cloudflare_tunnel_id
}

locals {
  # Define all managed hostnames and their origin services
  managed_apps = {
    "grafana.${var.domain}"        = "http://grafana.observability.svc.cluster.local:3000"
    "k8s.${var.domain}"            = "http://headlamp.headlamp.svc.cluster.local:4466"
    "ai-chat.${var.domain}"        = "http://openwebui.ai.svc.cluster.local:8080"
    "demo-semaphore.${var.domain}" = "http://semaphoreui.semaphoreui.svc.cluster.local:3000"
    "demo-argocd.${var.domain}"    = "http://argocd-server.argocd.svc.cluster.local:80"
    "storage.${var.domain}"        = "http://kong-kong-proxy.kong.svc.cluster.local:80"
    "demo-vault.${var.domain}"     = "http://vault.vault.svc.cluster.local:8200"
    "portainer.${var.domain}"      = "https://portainer.portainer.svc.cluster.local:9443"
    "homebox.${var.domain}"        = "http://homebox.homebox.svc.cluster.local:7745"
    "homepage.${var.domain}"       = "http://homepage.homepage.svc.cluster.local:3000"
    "forgejo.${var.domain}"        = "http://forgejo.forgejo.svc.cluster.local:3000"
    "n8n.${var.domain}"            = "http://n8n.n8n.svc.cluster.local:5678"
    "bookmarks.${var.domain}"      = "http://linkding.linkding.svc.cluster.local:9090"
    "demo-termix.${var.domain}"    = "http://termix.termix.svc.cluster.local:3000"
  }

  managed_hostnames = keys(local.managed_apps)

  # Keep existing ingress rules that we don't manage (e.g., auth.domain, other services)
  existing_ingress = try(data.cloudflare_zero_trust_tunnel_cloudflared_config.existing.config.ingress, [])

  retained_ingress = [
    for rule in local.existing_ingress : rule
    if !contains(local.managed_hostnames, try(rule.hostname, "")) && try(rule.service, "") != "http_status:404"
  ]

  # Build managed ingress rules
  managed_ingress = [
    for hostname, origin in local.managed_apps : {
      hostname = hostname
      service  = origin
    }
  ]
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "all_apps" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.cloudflare_tunnel_id

  config = {
    ingress = concat(
      local.retained_ingress,
      local.managed_ingress,
      [{ service = "http_status:404" }]
    )
  }

  lifecycle {
    prevent_destroy = true
  }
}
