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
  # NOTE: Use the Service port (not container/targetPort) when they differ.
  # kube-proxy DNATs ClusterIP:servicePort → PodIP:targetPort.
  # The cloudflared egress policy uses the post-DNAT port (targetPort).
  managed_apps = {
    "grafana.${var.domain}"        = { service = "http://grafana.observability.svc.cluster.local:3000" }
    "k8s.${var.domain}"            = { service = "http://headlamp.headlamp.svc.cluster.local:80" }
    "ai-chat.${var.domain}"        = { service = "http://openwebui.ai.svc.cluster.local:8080" }
    "demo-semaphore.${var.domain}" = { service = "http://semaphoreui.semaphoreui.svc.cluster.local:3000" }
    "demo-argocd.${var.domain}"    = { service = "http://argocd-server.argocd.svc.cluster.local:80" }
    "storage.${var.domain}"        = { service = "http://kong-kong-proxy.kong.svc.cluster.local:80" }
    "demo-vault.${var.domain}"     = { service = "http://vault.vault.svc.cluster.local:8200" }
    "portainer.${var.domain}"      = { service = "https://portainer.portainer.svc.cluster.local:9443", no_tls_verify = true }
    "homebox.${var.domain}"        = { service = "http://homebox.homebox.svc.cluster.local:80" }
    "homepage.${var.domain}"       = { service = "http://homepage.homepage.svc.cluster.local:80" }
    "forgejo.${var.domain}"        = { service = "http://forgejo.forgejo.svc.cluster.local:3000" }
    "n8n.${var.domain}"            = { service = "http://n8n.n8n.svc.cluster.local:80" }
    "bookmarks.${var.domain}"      = { service = "http://linkding.linkding.svc.cluster.local:9090" }
    "demo-termix.${var.domain}"    = { service = "http://termix.termix.svc.cluster.local:3000" }
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
    for hostname, config in local.managed_apps : merge(
      {
        hostname = hostname
        service  = config.service
      },
      lookup(config, "no_tls_verify", false) ? {
        origin_request = { no_tls_verify = true }
      } : {}
    )
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
