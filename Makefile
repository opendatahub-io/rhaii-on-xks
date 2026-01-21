.PHONY: deploy deploy-all undeploy status test help check-kubeconfig sync
.PHONY: deploy-cert-manager deploy-istio deploy-lws
.PHONY: undeploy-cert-manager undeploy-istio undeploy-lws

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

# Sync (fetch latest from git repos)
sync:
	@echo "=== Syncing helm repos ==="
	helmfile deps

# Deploy cert-manager + istio (default)
deploy: check-kubeconfig
	@echo "=== Deploying cert-manager + istio ==="
	helmfile apply --selector name=cert-manager-operator
	helmfile apply --selector name=sail-operator
	@$(MAKE) status

# Deploy all including lws
deploy-all: check-kubeconfig
	@echo "=== Deploying all (cert-manager + istio + lws) ==="
	helmfile apply
	@$(MAKE) status

# Deploy individual components
deploy-cert-manager: check-kubeconfig
	@echo "=== Deploying cert-manager ==="
	helmfile apply --selector name=cert-manager-operator

deploy-istio: check-kubeconfig
	@echo "=== Deploying istio ==="
	helmfile apply --selector name=sail-operator

deploy-lws: check-kubeconfig
	@echo "=== Deploying lws ==="
	helmfile apply --selector name=lws-operator

# Undeploy all
undeploy: check-kubeconfig
	@echo "=== Removing all ==="
	helmfile destroy
	@echo "=== Done ==="

# Undeploy individual components
undeploy-cert-manager: check-kubeconfig
	helmfile destroy --selector name=cert-manager-operator

undeploy-istio: check-kubeconfig
	helmfile destroy --selector name=sail-operator

undeploy-lws: check-kubeconfig
	helmfile destroy --selector name=lws-operator

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
