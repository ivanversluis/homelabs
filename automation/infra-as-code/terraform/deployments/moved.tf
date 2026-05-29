# ─────────────────────────────────────────────────────────────────────────────
# State Migration — Grafana
# ─────────────────────────────────────────────────────────────────────────────
# Grafana was previously applied from deployments/grafana/ as a standalone
# root module using module "grafana" { source = "../../compositions/oidc-app" }.
# The state paths were: module.grafana.module.{authentik,vault,cloudflare}.*
#
# Now Grafana is a child module of this root:
#   module.grafana → ./grafana/main.tf → module "oidc" → compositions/oidc-app
# New paths: module.grafana.module.oidc.module.{authentik,vault,cloudflare}.*
#
# These moved blocks migrate the Grafana state in-place on the next plan/apply.
# Safe to remove after a successful apply.
# ─────────────────────────────────────────────────────────────────────────────

moved {
  from = module.grafana.module.authentik
  to   = module.grafana.module.oidc.module.authentik
}

moved {
  from = module.grafana.module.vault
  to   = module.grafana.module.oidc.module.vault
}

moved {
  from = module.grafana.module.cloudflare
  to   = module.grafana.module.oidc.module.cloudflare
}
