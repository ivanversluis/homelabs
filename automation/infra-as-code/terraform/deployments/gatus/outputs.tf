output "cloudflare_access_policy_id" {
  description = "Cloudflare Access policy ID that allows the Gatus service token"
  value       = try(cloudflare_zero_trust_access_policy.allow_gatus_service_token[0].id, null)
}

output "cloudflare_access_service_token_id" {
  description = "Cloudflare Access service token ID for Gatus"
  value       = try(cloudflare_zero_trust_access_service_token.gatus[0].id, null)
}
