output "access_app_id" {
  description = "Cloudflare Access application ID"
  value       = try(cloudflare_zero_trust_access_application.app[0].id, null)
}

output "access_app_aud" {
  description = "Cloudflare Access application AUD tag"
  value       = try(cloudflare_zero_trust_access_application.app[0].aud, null)
}

output "hostname" {
  description = "Published hostname managed in the tunnel config"
  value       = var.app_domain
  sensitive   = true
}

output "origin_service" {
  description = "Origin service URL used by the tunnel"
  value       = var.origin_service
}

output "tunnel_id" {
  description = "Tunnel UUID whose config was updated"
  value       = var.tunnel_id
  sensitive   = true
}
