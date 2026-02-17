.PHONY: deploy deploy-all undeploy undeploy-kserve status help check-kubeconfig sync clear-cache
.PHONY: deploy-cert-manager deploy-istio deploy-kuadrant deploy-lws deploy-kserve deploy-opendatahub-prerequisites deploy-cert-manager-pki
.PHONY: test conformance

HELMFILE_CACHE := $(HOME)/.cache/helmfile
KSERVE_NAMESPACE ?= opendatahub

check-kubeconfig:
	@kubectl cluster-info >/dev/null 2>&1 || (echo "ERROR: Cannot connect to cluster. Check KUBECONFIG." && exit 1)

help:
	@echo "rhaii-on-xks - Infrastructure for llm-d on xKS (AKS/CoreWeave)"
	@echo ""
	@echo "Deploy:"
	@echo "  make deploy              - Deploy cert-manager + istio + kuadrant + lws"
	@echo "  make deploy-all          - Deploy all (cert-manager + istio + kuadrant + lws + kserve)"
	@echo "  make deploy-kuadrant     - Deploy Kuadrant/RHCL (API policies)"
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
	helmfile apply --selector name=kuadrant-operator
	helmfile apply --selector name=lws-operator
	@$(MAKE) status

deploy-all: check-kubeconfig deploy-cert-manager deploy-istio deploy-kuadrant deploy-lws deploy-kserve
	@$(MAKE) status

deploy-cert-manager: check-kubeconfig clear-cache
	helmfile apply --selector name=cert-manager-operator

deploy-istio: check-kubeconfig clear-cache deploy-cert-manager
	helmfile apply --selector name=sail-operator

deploy-kuadrant: check-kubeconfig clear-cache deploy-istio
	helmfile apply --selector name=kuadrant-operator

deploy-lws: check-kubeconfig clear-cache deploy-cert-manager
	helmfile apply --selector name=lws-operator

deploy-opendatahub-prerequisites: check-kubeconfig
	@echo "=== Deploying OpenDataHub prerequisites ==="
	kubectl create namespace $(KSERVE_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	-kubectl get secret redhat-pull-secret -n istio-system -o yaml 2>/dev/null | \
		sed 's/namespace: istio-system/namespace: $(KSERVE_NAMESPACE)/' | \
		kubectl apply -f - 2>/dev/null || true

deploy-cert-manager-pki: check-kubeconfig deploy-opendatahub-prerequisites
	@kubectl get crd clusterissuers.cert-manager.io >/dev/null 2>&1 || \
		(echo "ERROR: cert-manager CRDs not found. Run 'make deploy-cert-manager' first." && exit 1)
	@echo "Waiting for cert-manager webhook..."
	-kubectl delete secret cert-manager-webhook-ca -n cert-manager --ignore-not-found 2>/dev/null || true
	kubectl rollout restart deployment/cert-manager-webhook -n cert-manager
	kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s
	@echo "Waiting for webhook CA bundle to propagate..."
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12; do \
		if kubectl apply --dry-run=server -f ./charts/kserve/pki-prereq.yaml >/dev/null 2>&1; then \
			echo "  Webhook ready"; \
			break; \
		fi; \
		if [ $$i -eq 12 ]; then \
			echo "ERROR: cert-manager webhook not ready after 2 minutes"; \
			exit 1; \
		fi; \
		echo "  Webhook not ready yet, retrying in 10s... ($$i/12)"; \
		sleep 10; \
	done
	kubectl apply -f ./charts/kserve/pki-prereq.yaml
	kubectl wait --for=condition=Ready clusterissuer/opendatahub-ca-issuer --timeout=120s

deploy-kserve: check-kubeconfig deploy-cert-manager-pki deploy-istio deploy-lws
	@echo "Applying KServe via Helm..."
	helmfile sync --wait --selector name=kserve-rhaii-xks --skip-crds
	@echo "=== KServe deployed ==="

# Undeploy
undeploy: check-kubeconfig undeploy-kserve
	@./scripts/cleanup.sh -y

undeploy-kserve: check-kubeconfig
	-@kubectl delete llminferenceservice --all -A --ignore-not-found 2>/dev/null || true
	-@kubectl delete inferencepool --all -A --ignore-not-found 2>/dev/null || true
	-@helm uninstall kserve-rhaii-xks --namespace $(KSERVE_NAMESPACE) 2>/dev/null || true
	-@kubectl delete validatingwebhookconfiguration llminferenceservice.serving.kserve.io llminferenceserviceconfig.serving.kserve.io --ignore-not-found 2>/dev/null || true
	-@# Removes KServe CRDs and Inference Extension CRDs (Helm does not remove CRDs on uninstall)
	-@kubectl get crd -o name | grep -E "serving.kserve.io|inference.networking" | xargs -r kubectl delete --ignore-not-found 2>/dev/null || true
	-@# Removes cluster-scoped RBAC resources
	-@kubectl get clusterrole,clusterrolebinding -o name | grep -i kserve | xargs -r kubectl delete --ignore-not-found 2>/dev/null || true
	-@kubectl delete clusterissuer opendatahub-ca-issuer opendatahub-selfsigned-issuer --ignore-not-found 2>/dev/null || true
	-@kubectl delete certificate opendatahub-ca -n cert-manager --ignore-not-found 2>/dev/null || true
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
	@echo "kuadrant:"
	@kubectl get pods -n kuadrant-system 2>/dev/null || echo "  Not deployed"
	@echo ""
	@echo "lws-operator:"
	@kubectl get pods -n openshift-lws-operator 2>/dev/null || echo "  Not deployed"
	@echo ""
	@echo "kserve:"
	@kubectl get pods -n $(KSERVE_NAMESPACE) -l control-plane=kserve-controller-manager 2>/dev/null || echo "  Not deployed"
	@echo ""
	@echo "kserve config:"
	@kubectl get llminferenceserviceconfig -n $(KSERVE_NAMESPACE) 2>/dev/null || echo "  Not deployed"
	@echo ""
	@echo "=== Readiness Checks ==="
	@echo -n "cert-manager webhook: "
	@if kubectl get deployment cert-manager-webhook -n cert-manager >/dev/null 2>&1; then \
		if echo '{"apiVersion":"cert-manager.io/v1","kind":"ClusterIssuer","metadata":{"name":"webhook-readiness-test"},"spec":{"selfSigned":{}}}' | kubectl create -f - --dry-run=server -o yaml 2>/dev/null | grep -q 'webhook-readiness-test'; then \
			echo "Ready"; \
		else \
			echo "NOT READY (webhook CA may be stale — run: kubectl delete secret cert-manager-webhook-ca -n cert-manager && kubectl rollout restart deployment/cert-manager-webhook -n cert-manager)"; \
		fi; \
	else \
		echo "Not deployed"; \
	fi
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
