.PHONY: deploy deploy-all undeploy undeploy-kserve status help check-kubeconfig sync clear-cache
.PHONY: deploy-cert-manager deploy-istio deploy-lws deploy-kserve
.PHONY: test conformance

HELMFILE_CACHE := $(HOME)/.cache/helmfile
KSERVE_REF ?= rhoai-3.4
KSERVE_NAMESPACE ?= opendatahub # Note: this namespace can't be easily changed.

check-kubeconfig:
	@kubectl cluster-info >/dev/null 2>&1 || (echo "ERROR: Cannot connect to cluster. Check KUBECONFIG." && exit 1)

help:
	@echo "rhaii-on-xks - Infrastructure for llm-d on xKS (AKS/CoreWeave)"
	@echo ""
	@echo "Deploy:"
	@echo "  make deploy              - Deploy cert-manager + istio"
	@echo "  make deploy-all          - Deploy all (cert-manager + istio + lws)"
	@echo "  make deploy-kserve       - Deploy KServe"
	@echo ""
	@echo "Undeploy:"
	@echo "  make undeploy            - Remove all infrastructure"
	@echo "  make undeploy-kserve     - Remove KServe"
	@echo ""
	@echo "Other:"
	@echo "  make status              - Show deployment status"
	@echo "  make test                - Run ODH conformance tests"
	@echo "  make sync                - Fetch latest from git repos"
	@echo "  make clear-cache         - Clear helmfile git cache"

clear-cache:
	@echo "=== Clearing helmfile cache ==="
	helmfile cache info
	helmfile cache cleanup
	@echo "Cache cleared"

sync: clear-cache
	helmfile deps

# Deploy
deploy: check-kubeconfig clear-cache
	helmfile apply --selector name=cert-manager-operator
	helmfile apply --selector name=sail-operator
	@$(MAKE) status

deploy-all: check-kubeconfig clear-cache deploy-cert-manager deploy-istio deploy-lws deploy-kserve
	@$(MAKE) status

deploy-cert-manager: check-kubeconfig clear-cache
	helmfile apply --selector name=cert-manager-operator

deploy-istio: check-kubeconfig clear-cache
	helmfile apply --selector name=sail-operator

deploy-lws: check-kubeconfig clear-cache
	helmfile apply --selector name=lws-operator

deploy-opendatahub-prerequisites: check-kubeconfig
	@echo "=== Deploying OpenDataHub prerequisites ==="
	kubectl create namespace $(KSERVE_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	-kubectl get secret redhat-pull-secret -n istio-system -o yaml 2>/dev/null | \
		sed 's/namespace: istio-system/namespace: $(KSERVE_NAMESPACE)/' | \
		kubectl apply -f - 2>/dev/null || true

deploy-cert-manager-pki: check-kubeconfig deploy-opendatahub-prerequisites
	kubectl apply -k "https://github.com/red-hat-data-services/kserve/config/overlays/odh-test/cert-manager?ref=$(KSERVE_REF)"
	kubectl wait --for=condition=Ready clusterissuer/opendatahub-ca-issuer --timeout=120s
	kubectl wait --for=condition=Ready certificate/kserve-webhook-server -n opendatahub --timeout=120s

deploy-kserve: check-kubeconfig clear-cache deploy-cert-manager-pki
	@echo "Applying KServe via Helm..."
	helmfile sync --wait --selector name=kserve-rhaii-xks --skip-crds
	@echo "=== KServe deployed ==="

# Undeploy
undeploy: check-kubeconfig
	@./scripts/cleanup.sh -y

# Status
status: check-kubeconfig
	@echo ""
	@echo "=== Deployment Status ==="
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
	@echo ""
	@echo "=== API Versions ==="
	@echo -n "InferencePool API: "
	@if kubectl get crd inferencepools.inference.networking.k8s.io >/dev/null 2>&1; then \
		echo "v1 (inference.networking.k8s.io)"; \
	elif kubectl get crd inferencepools.inference.networking.x-k8s.io >/dev/null 2>&1; then \
		echo "v1alpha2 (inference.networking.x-k8s.io)"; \
	else \
		echo "Not installed"; \
	fi
	@echo -n "Istio version: "
	@kubectl get istio default -n istio-system -o jsonpath='{.spec.version}' 2>/dev/null || echo "Not deployed"
	@echo ""

# Test/Conformance (ODH deployment validation)
NAMESPACE ?= llm-d
PROFILE ?= kserve-basic

test: conformance

conformance: check-kubeconfig
	@./test/conformance/verify-llm-d-deployment.sh --namespace $(NAMESPACE) --profile $(PROFILE)
