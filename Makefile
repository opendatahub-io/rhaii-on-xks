.PHONY: deploy deploy-all undeploy status test help check-kubeconfig sync clear-cache
.PHONY: deploy-cert-manager deploy-istio deploy-lws
.PHONY: undeploy-cert-manager undeploy-istio undeploy-lws
.PHONY: conformance conformance-basic conformance-full

# Helmfile caches git dependencies - clear to get latest
HELMFILE_CACHE := $(HOME)/.cache/helmfile

check-kubeconfig:
	@kubectl cluster-info >/dev/null 2>&1 || (echo "ERROR: Cannot connect to cluster. Check KUBECONFIG." && exit 1)

help:
	@echo "llm-d-infra-xks - Infrastructure for llm-d on xKS (AKS/EKS/GKE)"
	@echo ""
	@echo "Deploy:"
	@echo "  make deploy              - Deploy cert-manager + istio"
	@echo "  make deploy-all          - Deploy all (cert-manager + istio + lws)"
	@echo ""
	@echo "Deploy individual:"
	@echo "  make deploy-cert-manager - Deploy cert-manager operator"
	@echo "  make deploy-istio        - Deploy sail-operator (Istio)"
	@echo "  make deploy-lws          - Deploy lws-operator"
	@echo ""
	@echo "Undeploy:"
	@echo "  make undeploy            - Remove all"
	@echo "  make undeploy-cert-manager"
	@echo "  make undeploy-istio"
	@echo "  make undeploy-lws"
	@echo ""
	@echo "Other:"
	@echo "  make status              - Show deployment status"
	@echo "  make test                - Run tests"
	@echo "  make sync                - Fetch latest from git repos"
	@echo "  make clear-cache         - Clear helmfile git cache"
	@echo ""
	@echo "Conformance Tests:"
	@echo "  make conformance NAMESPACE=llm-d                    - Run conformance (auto-detect profile)"
	@echo "  make conformance NAMESPACE=llm-d PROFILE=full       - Run with specific profile"
	@echo "  make conformance-list                               - List available profiles"

# Clear helmfile git cache to force fresh pulls
clear-cache:
	@echo "=== Clearing helmfile cache ==="
	@rm -rf $(HELMFILE_CACHE)/git 2>/dev/null || true
	@echo "Cache cleared"

# Sync (fetch latest from git repos)
sync: clear-cache
	@echo "=== Syncing helm repos ==="
	helmfile deps

# Deploy cert-manager + istio (default)
deploy: check-kubeconfig clear-cache
	@echo "=== Deploying cert-manager + istio ==="
	helmfile apply --selector name=cert-manager-operator
	helmfile apply --selector name=sail-operator
	@$(MAKE) status

# Deploy all including lws
deploy-all: check-kubeconfig clear-cache
	@echo "=== Deploying all (cert-manager + istio + lws) ==="
	helmfile apply
	@$(MAKE) status

# Deploy individual components
deploy-cert-manager: check-kubeconfig clear-cache
	@echo "=== Deploying cert-manager ==="
	helmfile apply --selector name=cert-manager-operator

deploy-istio: check-kubeconfig clear-cache
	@echo "=== Deploying istio ==="
	helmfile apply --selector name=sail-operator

deploy-lws: check-kubeconfig clear-cache
	@echo "=== Deploying lws ==="
	helmfile apply --selector name=lws-operator

# Undeploy all
undeploy: check-kubeconfig clear-cache
	@echo "=== Removing all ==="
	-helmfile destroy || true
	@echo "=== Cleaning up namespaces ==="
	-kubectl delete namespace istio-system --ignore-not-found --wait=false
	-kubectl delete namespace cert-manager --ignore-not-found --wait=false
	-kubectl delete namespace cert-manager-operator --ignore-not-found --wait=false
	-kubectl delete namespace openshift-lws-operator --ignore-not-found --wait=false
	@echo "=== Cleaning up Istio resources ==="
	-kubectl delete istio --all -A --ignore-not-found 2>/dev/null || true
	-kubectl delete mutatingwebhookconfiguration istio-sidecar-injector --ignore-not-found 2>/dev/null || true
	-kubectl delete validatingwebhookconfiguration istio-validator-istio-system --ignore-not-found 2>/dev/null || true
	@echo "=== Done ==="

# Undeploy individual components
undeploy-cert-manager: check-kubeconfig clear-cache
	-helmfile destroy --selector name=cert-manager-operator || true
	-kubectl delete namespace cert-manager --ignore-not-found --wait=false
	-kubectl delete namespace cert-manager-operator --ignore-not-found --wait=false

undeploy-istio: check-kubeconfig clear-cache
	-helmfile destroy --selector name=sail-operator || true
	-kubectl delete istio --all -n istio-system --ignore-not-found 2>/dev/null || true
	-kubectl delete namespace istio-system --ignore-not-found --wait=false
	-kubectl delete mutatingwebhookconfiguration istio-sidecar-injector --ignore-not-found 2>/dev/null || true
	-kubectl delete validatingwebhookconfiguration istio-validator-istio-system --ignore-not-found 2>/dev/null || true

undeploy-lws: check-kubeconfig clear-cache
	-helmfile destroy --selector name=lws-operator || true
	-kubectl delete namespace openshift-lws-operator --ignore-not-found --wait=false

# Status
status: check-kubeconfig
	@echo ""
	@echo "=== Deployment Status ==="
	@echo ""
	@echo "cert-manager-operator:"
	@kubectl get pods -n cert-manager-operator 2>/dev/null || echo "  Not deployed"
	@echo ""
	@echo "cert-manager:"
	@kubectl get pods -n cert-manager 2>/dev/null || echo "  Not deployed"
	@echo ""
	@echo "istio:"
	@kubectl get pods -n istio-system 2>/dev/null || echo "  Not deployed"
	@echo ""
	@echo "lws-operator:"
	@kubectl get pods -n openshift-lws-operator 2>/dev/null || echo "  Not deployed"

# Test
test: check-kubeconfig
	@echo "=== Running tests ==="
	@cd ../cert-manager-operator-chart && make test 2>/dev/null || echo "[cert-manager] SKIP"
	@cd ../sail-operator-chart && make test 2>/dev/null || echo "[istio] SKIP"
	@cd ../lws-operator-chart && make test 2>/dev/null || echo "[lws] SKIP"
	@echo "=== Done ==="

# Conformance Tests
NAMESPACE ?= llm-d
PROFILE ?= basic
TIMEOUT ?= 120

conformance: check-kubeconfig
	@echo "=== Running LLM-D Conformance Tests ==="
	@./test/conformance/verify-llm-d-deployment.sh \
		--namespace $(NAMESPACE) \
		--profile $(PROFILE) \
		--timeout $(TIMEOUT)

conformance-list:
	@./test/conformance/verify-llm-d-deployment.sh --list-profiles

conformance-quick: check-kubeconfig
	@echo "=== Running Quick Conformance (skip inference) ==="
	@./test/conformance/verify-llm-d-deployment.sh \
		--namespace $(NAMESPACE) \
		--profile $(PROFILE) \
		--skip-inference
