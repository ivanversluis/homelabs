# ============================================================================
# Homelab Cluster Validation Makefile
# ============================================================================
# Usage:
#   make iam-validate-oidc          — Validate all OIDC integrations
#   make iam-validate-oidc-app APP=openwebui  — Single app
#   make zt-validate                — Run Zero Trust network policy validation
#   make zt-validate-ns NS=ai       — Test a single namespace
#   make zt-cf                      — Test Cloudflare tunnel endpoints
# ============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Resolve domain from cluster secret (never hardcode)
DOMAIN := $(shell kubectl get secret flux-domain-vars -n flux-system -o jsonpath='{.data.DOMAIN}' 2>/dev/null | base64 -d)

.PHONY: help iam-validate-oidc iam-validate-oidc-app zt-validate zt-validate-ns zt-cf

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

