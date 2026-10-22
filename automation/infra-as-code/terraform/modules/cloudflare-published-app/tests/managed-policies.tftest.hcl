mock_provider "cloudflare" {
  mock_resource "cloudflare_zero_trust_access_application" {
    defaults = {
      id  = "test-managed-app-id"
      aud = "test-managed-app-aud"
    }
  }
}

variables {
  account_id           = "test-account"
  tunnel_id            = "test-tunnel"
  app_name             = "Test"
  app_domain           = "test.example.com"
  origin_service       = "http://test:80"
  manage_tunnel_config = false
  policy_ids           = ["policy-a", "policy-b"]
}

run "managed_create" {
  command = apply

  assert {
    condition     = length(cloudflare_zero_trust_access_application.app) == 0 && length(cloudflare_zero_trust_access_application.app_managed) == 1
    error_message = "Explicit IDs must select Terraform ownership."
  }
}

run "managed_update" {
  command = plan
  variables {
    policy_ids = ["policy-b", "policy-c"]
  }

  assert {
    condition = (
      [for p in cloudflare_zero_trust_access_application.app_managed[0].policies : p.id] == ["policy-b", "policy-c"] &&
      [for p in cloudflare_zero_trust_access_application.app_managed[0].policies : p.precedence] == [1, 2]
    )
    error_message = "Policy addition/removal and precedence changes must appear in the next plan."
  }
  assert {
    condition     = output.access_app_id == "test-managed-app-id" && output.access_app_aud == "test-managed-app-aud"
    error_message = "Policy updates must retain the existing application ID and AUD."
  }
}
