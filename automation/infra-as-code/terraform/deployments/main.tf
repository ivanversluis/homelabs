# ─────────────────────────────────────────────────────────────────────────────
# OIDC SSO — Application Index
# ─────────────────────────────────────────────────────────────────────────────
# This file is the only place to edit when onboarding a new application:
#   1. Add a module block below pointing to a new subfolder
#   2. Create the subfolder with main.tf / variables.tf / outputs.tf
#
# Run from this directory:  terraform init && terraform plan && terraform apply
# ─────────────────────────────────────────────────────────────────────────────

locals {
  cf = {
    account_id = var.cloudflare_account_id
    tunnel_id  = var.cloudflare_tunnel_id
    team_name  = var.cloudflare_team_name
  }
}

# ── Infrastructure Applications ──────────────────────────────────────────────

module "grafana" {
  source                = "./grafana"
  domain                = var.domain
  cloudflare_account_id = local.cf.account_id
  cloudflare_tunnel_id  = local.cf.tunnel_id
  cloudflare_team_name  = local.cf.team_name
}

module "headlamp" {
  source                = "./headlamp"
  domain                = var.domain
  cloudflare_account_id = local.cf.account_id
  cloudflare_tunnel_id  = local.cf.tunnel_id
  cloudflare_team_name  = local.cf.team_name
}

module "openwebui" {
  source                = "./openwebui"
  domain                = var.domain
  cloudflare_account_id = local.cf.account_id
  cloudflare_tunnel_id  = local.cf.tunnel_id
  cloudflare_team_name  = local.cf.team_name
}

module "semaphoreui" {
  source                = "./semaphoreui"
  domain                = var.domain
  cloudflare_account_id = local.cf.account_id
  cloudflare_tunnel_id  = local.cf.tunnel_id
  cloudflare_team_name  = local.cf.team_name
}

module "argocd" {
  source                = "./argocd"
  domain                = var.domain
  cloudflare_account_id = local.cf.account_id
  cloudflare_tunnel_id  = local.cf.tunnel_id
  cloudflare_team_name  = local.cf.team_name
}

module "longhorn" {
  source                = "./longhorn"
  domain                = var.domain
  cloudflare_account_id = local.cf.account_id
  cloudflare_tunnel_id  = local.cf.tunnel_id
  cloudflare_team_name  = local.cf.team_name
}

module "vault" {
  source                = "./vault"
  domain                = var.domain
  cloudflare_account_id = local.cf.account_id
  cloudflare_tunnel_id  = local.cf.tunnel_id
  cloudflare_team_name  = local.cf.team_name
}

module "portainer" {
  source                = "./portainer"
  domain                = var.domain
  cloudflare_account_id = local.cf.account_id
  cloudflare_tunnel_id  = local.cf.tunnel_id
  cloudflare_team_name  = local.cf.team_name
}

# ── User Applications ─────────────────────────────────────────────────────────

module "homebox" {
  source                = "./homebox"
  domain                = var.domain
  cloudflare_account_id = local.cf.account_id
  cloudflare_tunnel_id  = local.cf.tunnel_id
  cloudflare_team_name  = local.cf.team_name
}

module "homepage" {
  source                = "./homepage"
  domain                = var.domain
  cloudflare_account_id = local.cf.account_id
  cloudflare_tunnel_id  = local.cf.tunnel_id
  cloudflare_team_name  = local.cf.team_name
}

module "forgejo" {
  source                = "./forgejo"
  domain                = var.domain
  cloudflare_account_id = local.cf.account_id
  cloudflare_tunnel_id  = local.cf.tunnel_id
  cloudflare_team_name  = local.cf.team_name
}

module "n8n" {
  source                = "./n8n"
  domain                = var.domain
  cloudflare_account_id = local.cf.account_id
  cloudflare_tunnel_id  = local.cf.tunnel_id
  cloudflare_team_name  = local.cf.team_name
}

module "linkding" {
  source                = "./linkding"
  domain                = var.domain
  cloudflare_account_id = local.cf.account_id
  cloudflare_tunnel_id  = local.cf.tunnel_id
  cloudflare_team_name  = local.cf.team_name
}

module "termix" {
  source                = "./termix"
  domain                = var.domain
  cloudflare_account_id = local.cf.account_id
  cloudflare_tunnel_id  = local.cf.tunnel_id
  cloudflare_team_name  = local.cf.team_name
}


