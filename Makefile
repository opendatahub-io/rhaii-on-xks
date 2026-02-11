.PHONY: deploy deploy-all undeploy undeploy-kserve status help check-kubeconfig sync clear-cache
.PHONY: deploy-cert-manager deploy-istio deploy-lws deploy-kserve
.PHONY: test conformance

HELMFILE_CACHE := $(HOME)/.cache/helmfile
KSERVE_REF ?= release-v0.15
KSERVE_NAMESPACE ?= opendatahub

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

deploy-all: check-kubeconfig clear-cache
	helmfile apply
	@$(MAKE) status

deploy-cert-manager: check-kubeconfig clear-cache
	helmfile apply --selector name=cert-manager-operator

deploy-istio: check-kubeconfig clear-cache
	helmfile apply --selector name=sail-operator

deploy-lws: check-kubeconfig clear-cache
	helmfile apply --selector name=lws-operator

deploy-kserve: check-kubeconfig
	@echo "=== Deploying KServe (ref=$(KSERVE_REF)) ==="
	kubectl create namespace $(KSERVE_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	-kubectl get secret redhat-pull-secret -n istio-system -o yaml 2>/dev/null | \
		sed 's/namespace: istio-system/namespace: $(KSERVE_NAMESPACE)/' | \
		kubectl apply -f - 2>/dev/null || true
	kubectl apply -k "https://github.com/opendatahub-io/kserve/config/overlays/odh-test/cert-manager?ref=$(KSERVE_REF)"
	kubectl wait --for=condition=Ready clusterissuer/opendatahub-ca-issuer --timeout=120s
	@echo "Applying CRDs and deployment (CR errors expected, will retry)..."
	-kustomize build "https://github.com/opendatahub-io/kserve/config/overlays/odh-xks?ref=$(KSERVE_REF)" | kubectl apply --server-side --force-conflicts -f - 2>/dev/null || true
	@echo "Removing webhooks to allow controller startup..."
	-kubectl delete validatingwebhookconfiguration llminferenceservice.serving.kserve.io llminferenceserviceconfig.serving.kserve.io --ignore-not-found 2>/dev/null || true
	kubectl wait --for=condition=Available deployment/kserve-controller-manager -n $(KSERVE_NAMESPACE) --timeout=300s
	@echo "Controller ready, applying CRs..."
	kustomize build "https://github.com/opendatahub-io/kserve/config/overlays/odh-xks?ref=$(KSERVE_REF)" | kubectl apply --server-side --force-conflicts -f -
	@echo "=== KServe deployed ==="

# Undeploy
undeploy: check-kubeconfig
	@./scripts/cleanup.sh -y

undeploy-kserve: check-kubeconfig
	-@kubectl delete llminferenceservice --all -A --ignore-not-found 2>/dev/null || true
	-@kubectl delete inferencepool --all -A --ignore-not-found 2>/dev/null || true
	-@kubectl delete deployment kserve-controller-manager -n $(KSERVE_NAMESPACE) --ignore-not-found 2>/dev/null || true
	-@kubectl delete validatingwebhookconfiguration llminferenceservice.serving.kserve.io llminferenceserviceconfig.serving.kserve.io --ignore-not-found 2>/dev/null || true
	-@# Removes KServe CRDs and Inference Extension CRDs (InferencePool, InferenceModel)
	-@kubectl get crd -o name | grep -E "serving.kserve.io|inference.networking" | xargs -r kubectl delete --ignore-not-found 2>/dev/null || true
	-@kubectl delete clusterissuer opendatahub-ca-issuer --ignore-not-found 2>/dev/null || true
	-@kubectl delete namespace $(KSERVE_NAMESPACE) --ignore-not-found --wait=false 2>/dev/null || true
	@echo "=== KServe removed ==="

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
