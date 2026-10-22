mock_provider "cloudflare" {
  mock_resource "cloudflare_zero_trust_access_application" {
    defaults = {
      id  = "test-app-id"
      aud = "test-app-aud"
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
}

run "dashboard_create" {
  command = apply

  assert {
    condition     = length(cloudflare_zero_trust_access_application.app) == 1 && length(cloudflare_zero_trust_access_application.app_managed) == 0
    error_message = "Dashboard ownership must preserve the original resource address."
  }
}

run "dashboard_preserve" {
  command = plan

  assert {
    condition     = length(cloudflare_zero_trust_access_application.app) == 1 && length(cloudflare_zero_trust_access_application.app_managed) == 0
    error_message = "A subsequent plan must keep the existing dashboard application address."
  }
  assert {
    condition     = output.access_app_id == "test-app-id" && output.access_app_aud == "test-app-aud"
    error_message = "Dashboard ownership must preserve application outputs."
  }
}
