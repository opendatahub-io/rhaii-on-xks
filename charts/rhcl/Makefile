SHELL := /bin/bash
CHART_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
OPERATOR_NAMESPACE ?= kuadrant-operators
INSTANCE_NAMESPACE ?= kuadrant-system

.PHONY: help check install validate status logs destroy lint template test test-dns clean-crds copy-crds

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Pre-deploy
# ---------------------------------------------------------------------------

check: ## Run pre-deployment checks (cluster, cert-manager, Gateway API, registry auth)
	@bash $(CHART_DIR)/scripts/pre-deploy-check.sh

copy-crds: ## Copy and deduplicate CRDs from mpaul's chart
	@bash $(CHART_DIR)/scripts/copy-crds.sh

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------

lint: ## Run helm lint on the chart
	helm lint $(CHART_DIR)

template: ## Render Helm templates to stdout
	helm template rhcl $(CHART_DIR)

install: ## Deploy RHCL via helmfile
	cd $(CHART_DIR) && helmfile apply

# ---------------------------------------------------------------------------
# Post-deploy
# ---------------------------------------------------------------------------

validate: ## Run post-deployment validation
	@OPERATOR_NAMESPACE=$(OPERATOR_NAMESPACE) INSTANCE_NAMESPACE=$(INSTANCE_NAMESPACE) \
		bash $(CHART_DIR)/manifests-postsync/validate.sh

status: ## Show RHCL resource status across all namespaces
	@echo "=== Operators ($(OPERATOR_NAMESPACE)) ==="
	@kubectl get deployment -n $(OPERATOR_NAMESPACE) 2>/dev/null || echo "  Namespace not found"
	@echo ""
	@echo "=== Instances ($(INSTANCE_NAMESPACE)) ==="
	@kubectl get kuadrant,authorino,limitador -n $(INSTANCE_NAMESPACE) 2>/dev/null || echo "  No instances found"
	@echo ""
	@echo "=== Component Pods ($(INSTANCE_NAMESPACE)) ==="
	@kubectl get pods -n $(INSTANCE_NAMESPACE) 2>/dev/null || echo "  No pods found"
	@echo ""
	@echo "=== Kuadrant CRDs ==="
	@kubectl get crd -o name 2>/dev/null | grep -c "kuadrant\\.io" | xargs -I{} echo "  {} Kuadrant CRDs installed"
	@echo ""
	@echo "=== Policies (all namespaces) ==="
	@kubectl get authpolicy,ratelimitpolicy,tlspolicy -A 2>/dev/null || echo "  No policies found"

logs: ## Tail operator logs (use OPERATOR= to select: kuadrant, authorino, limitador, dns)
	$(eval OPERATOR ?= kuadrant)
	$(eval POD_LABEL := $(if $(filter kuadrant,$(OPERATOR)),app.kubernetes.io/component=kuadrant-operator,$(if $(filter authorino,$(OPERATOR)),app.kubernetes.io/component=authorino-operator,$(if $(filter limitador,$(OPERATOR)),app.kubernetes.io/component=limitador-operator,app.kubernetes.io/component=dns-operator))))
	kubectl logs -f -l $(POD_LABEL) -n $(OPERATOR_NAMESPACE) --tail=100

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

test: ## Run integration test (deploys test resources, validates, cleans up)
	@bash $(CHART_DIR)/../../test/conformance/verify-rhcl-deployment.sh

test-dns: ## Run DNS operator test
	@bash $(CHART_DIR)/../../test/conformance/verify-rhcl-dns.sh

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

destroy: ## Remove RHCL via helmfile destroy
	cd $(CHART_DIR) && helmfile destroy

clean-crds: ## Remove all RHCL CRDs from cluster (destructive!)
	@bash $(CHART_DIR)/scripts/clean-crds.sh
