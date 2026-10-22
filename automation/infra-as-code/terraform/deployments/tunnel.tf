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
    "grafana.${var.domain}"     = { service = "http://grafana.observability.svc.cluster.local:3000" }
    "headlamp.${var.domain}"    = { service = "http://headlamp.headlamp.svc.cluster.local:80" }
    "openwebui.${var.domain}"   = { service = "http://openwebui.ai.svc.cluster.local:8080" }
    "semaphoreui.${var.domain}" = { service = "http://semaphoreui.semaphoreui.svc.cluster.local:3000" }
    "argocd.${var.domain}"      = { service = "http://argocd-server.argocd.svc.cluster.local:80" }
    "storage.${var.domain}"     = { service = "http://kong-kong-proxy.kong.svc.cluster.local:80" }
    "vault.${var.domain}"       = { service = "http://vault.vault.svc.cluster.local:8200" }
    "portainer.${var.domain}"   = { service = "https://portainer.portainer.svc.cluster.local:9443", no_tls_verify = true }
    "homebox.${var.domain}"     = { service = "http://homebox.homebox.svc.cluster.local:80" }
    "homepage.${var.domain}"    = { service = "http://homepage.homepage.svc.cluster.local:80" }
    "forgejo.${var.domain}"     = { service = "http://forgejo.forgejo.svc.cluster.local:3000" }
    "n8n.${var.domain}"         = { service = "http://n8n.n8n.svc.cluster.local:80" }
    "bookmarks.${var.domain}"   = { service = "http://linkding.linkding.svc.cluster.local:9090" }
    "termix.${var.domain}"      = { service = "http://termix.termix.svc.cluster.local:3000" }
    "stargate.${var.domain}"    = { service = "http://vaultwarden.vaultwarden.svc.cluster.local:80" }
    "gatus.${var.domain}"       = { service = "http://kong-kong-proxy.kong.svc.cluster.local:80" }
  }

  managed_hostnames = keys(local.managed_apps)

  # Live is leading: every rule already in the tunnel is kept exactly as it is
  # (stale old-domain rules, hand-added routes, duplicates, services and ports).
  existing_ingress = try(data.cloudflare_zero_trust_tunnel_cloudflared_config.existing.config.ingress, [])
  existing_rules   = [for rule in local.existing_ingress : rule if try(rule.service, "") != "http_status:404"]
  existing_hosts   = [for rule in local.existing_rules : try(rule.hostname, "")]

  # Only managed hostnames that are missing from the live tunnel are added.
  missing_ingress = [
    for hostname, config in local.managed_apps : merge(
      {
        hostname = hostname
        service  = config.service
      },
      lookup(config, "no_tls_verify", false) ? {
        origin_request = { no_tls_verify = true }
      } : {}
    ) if !contains(local.existing_hosts, hostname)
  ]

  # Apps published through the tunnel that had no DNS record on the current zone.
  # The other records were created in the Cloudflare dashboard and are not managed.
  dns_missing_apps = toset(["bookmarks", "headlamp", "homebox", "portainer"])
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "all_apps" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.cloudflare_tunnel_id

  config = {
    ingress = concat(
      local.existing_rules,
      local.missing_ingress,
      [{ service = "http_status:404" }]
    )
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_dns_record" "published_app" {
  for_each = local.dns_missing_apps

  zone_id = var.cloudflare_zone_id
  name    = each.key
  type    = "CNAME"
  content = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}
