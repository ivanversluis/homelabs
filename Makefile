# ============================================================================
# Homelab Cluster Validation Makefile
# ============================================================================
# Usage:
#   make iam-validate-oidc          — Validate all OIDC integrations
#   make iam-validate-oidc-app APP=openwebui  — Single app
#   make zt-validate                — Run Zero Trust network policy validation
#   make zt-validate-ns NS=ai       — Test a single namespace
#   make zt-cf                      — Test Cloudflare tunnel endpoints
#   make tf-init APP=grafana        — Terraform init for a deployment
#   make tf-plan APP=grafana        — Terraform plan for a deployment
#   make tf-apply APP=grafana       — Terraform apply (auto-approve)
# ============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Resolve domain from cluster secret (never hardcode)
DOMAIN := $(shell kubectl get secret flux-domain-vars -n flux-system -o jsonpath='{.data.DOMAIN}' 2>/dev/null | base64 -d)

.PHONY: help iam-validate-oidc iam-validate-oidc-app zt-validate zt-validate-ns zt-cf tf-init tf-plan tf-apply

help: ## Show available targets
	@echo "Usage: make <target> [options]"
	@echo ""
	@echo "IAM Targets:"
	@echo "  iam-validate-oidc              Validate all OIDC callback integrations"
	@echo "  iam-validate-oidc-app APP=x    Validate OIDC for a single app"
	@echo ""
	@echo "Zero Trust Targets:"
	@echo "  zt-validate                    Run network policy validation"
	@echo "  zt-validate-ns NS=x           Validate a single namespace"
	@echo "  zt-cf                          Test Cloudflare tunnel endpoints"
	@echo ""
	@echo "Terraform Targets:"
	@echo "  tf-init APP=x                  Terraform init for a deployment"
	@echo "  tf-plan APP=x                  Terraform plan for a deployment"
	@echo "  tf-apply APP=x                 Terraform apply (auto-approve)"

# ============================================================================
# IAM Targets
# ============================================================================

iam-validate-oidc: ## Validate all OIDC callback integrations
	@if [ -z "$(DOMAIN)" ]; then echo "ERROR: Cannot resolve domain from flux-domain-vars secret"; exit 1; fi
	@bash scripts/iam-oidc-callback-validation.sh $(ARGS)

iam-validate-oidc-app: ## Validate OIDC for a single app (APP=name)
	@if [ -z "$(APP)" ]; then echo "ERROR: APP= is required"; exit 1; fi
	@bash scripts/iam-oidc-callback-validation.sh --app $(APP)

# ============================================================================
# Zero Trust Targets
# ============================================================================

zt-validate: ## Run Zero Trust network policy validation
	@if [ -z "$(DOMAIN)" ]; then echo "ERROR: Cannot resolve domain from flux-domain-vars secret"; exit 1; fi
	@bash scripts/zero-trust-validate.sh $(ARGS)

zt-validate-ns: ## Validate a single namespace (NS=namespace)
	@if [ -z "$(NS)" ]; then echo "ERROR: NS= is required"; exit 1; fi
	@bash scripts/zero-trust-validate.sh --namespace $(NS)

zt-cf: ## Test all Cloudflare tunnel endpoints
	@if [ -z "$(DOMAIN)" ]; then echo "ERROR: Cannot resolve domain from flux-domain-vars secret"; exit 1; fi
	@bash scripts/zero-trust-test-tunnel-endpoints.sh $(ARGS)

# ============================================================================
# Terraform Targets
# ============================================================================

TF_DIR := automation/infra-as-code/terraform/deployments

tf-init: ## Terraform init (APP=deployment_name)
	@if [ -z "$(APP)" ]; then echo "ERROR: APP= is required (e.g., APP=grafana)"; exit 1; fi
	@cd $(TF_DIR)/$(APP) && terraform init

tf-plan: ## Terraform plan (APP=deployment_name)
	@if [ -z "$(APP)" ]; then echo "ERROR: APP= is required (e.g., APP=grafana)"; exit 1; fi
	@cd $(TF_DIR)/$(APP) && terraform plan

tf-apply: ## Terraform apply with auto-approve (APP=deployment_name)
	@if [ -z "$(APP)" ]; then echo "ERROR: APP= is required (e.g., APP=grafana)"; exit 1; fi
	@cd $(TF_DIR)/$(APP) && terraform apply -auto-approve

