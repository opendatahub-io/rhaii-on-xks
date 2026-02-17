.PHONY: deploy undeploy status verify logs clean help check-kubeconfig

NAMESPACE ?= kuadrant-system

check-kubeconfig:
	@kubectl cluster-info >/dev/null 2>&1 || (echo "ERROR: Cannot connect to cluster. Check KUBECONFIG is set and valid." && exit 1)

help:
	@echo "Usage:"
	@echo " make deploy  - Deploy RHCL operator (helmfile apply)"
	@echo " make undeploy - Remove RHCL operator"
	@echo " make status  - Show deployment status"
	@echo " make verify  - Verify all components are running"
	@echo " make logs   - Show operator logs"
	@echo " make clean   - Full cleanup including namespace"

deploy: check-kubeconfig
	@echo "=== Deploying Red Hat Connectivity Link (RHCL) ==="
	helmfile apply
	@echo "=== RHCL deployed ==="

undeploy: check-kubeconfig
	@echo "=== Removing RHCL operator ==="
	helmfile destroy
	@echo "=== RHCL removed ==="

status: check-kubeconfig
	@echo "=== RHCL Deployment Status ==="
	@kubectl get pods -n $(NAMESPACE)
	@echo ""
	@kubectl get kuadrant -n $(NAMESPACE) || echo "Kuadrant CR not found (CRD may not be installed yet)"

verify: check-kubeconfig
	@echo "=== Verifying RHCL Components ==="
	@echo "Checking Kuadrant operator..."
	@kubectl get deployment kuadrant-operator-controller-manager -n $(NAMESPACE) || echo "Operator not found"
	@echo ""
	@echo "Checking Kuadrant CR..."
	@kubectl get kuadrant kuadrant -n $(NAMESPACE) || echo "Kuadrant CR not found"
	@echo ""
	@echo "Checking Policy CRDs..."
	@kubectl get crd | grep kuadrant || echo "No Kuadrant CRDs found"

logs: check-kubeconfig
	@kubectl logs -n $(NAMESPACE) -l control-plane=kuadrant-operator-controller-manager --tail=100

clean: check-kubeconfig
	@echo "=== Full cleanup ==="
	helmfile destroy || true
	kubectl delete namespace $(NAMESPACE) --ignore-not-found=true
	@echo "=== Cleanup complete ==="
