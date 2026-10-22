# One-time adoption of the Gatus objects that already exist live but are missing
# from the Terraform state (config-driven import, Terraform >= 1.5). The plan
# shows them as "will be imported"; no infrastructure is changed by the import
# itself. Remove this file after the first successful apply.
#
# Not imported on purpose:
# - Vault secret/policy, tunnel ingress rule: already in state.
# - Authentik application entitlement: does not exist live yet, so it is created.
# - random_id.client_id / random_password: the provider ignores client_id and
#   client_secret changes, and the cookie secret is simply generated.

import {
  to = module.gatus.module.authentik.authentik_group.groups["Gatus Users"]
  id = "a8178283-3dfd-47f2-9023-74f9694b962d"
}

import {
  to = module.gatus.module.authentik.authentik_provider_oauth2.provider
  id = "28"
}

import {
  to = module.gatus.module.authentik.authentik_application.app
  id = "gatus"
}

# The state still references a record ID from before the domain/zone change
# (it returns 404 now); run
#   terraform state rm module.gatus.cloudflare_dns_record.gatus_cname
# once before the first plan so this import can adopt the live CNAME.
import {
  to = module.gatus.cloudflare_dns_record.gatus_cname
  id = "${var.cloudflare_zone_id}/e6e5b34ed814d6484024a2788088471f"
}
