.PHONY: deploy undeploy test test-operator test-crd test-injection update-bundle list-versions clean help check-kubeconfig

NAMESPACE ?= istio-system
TIMEOUT ?= 120
VERSION ?= 3.2.1
SOURCE ?= redhat

export NAMESPACE
export TIMEOUT
export TEST_NAMESPACE = sail-test

check-kubeconfig:
	@kubectl cluster-info >/dev/null 2>&1 || (echo "ERROR: Cannot connect to cluster. Check KUBECONFIG is set and valid." && exit 1)

help:
	@echo "Usage:"
	@echo "  make deploy         - Deploy Sail operator (helmfile apply)"
	@echo "  make undeploy       - Remove Sail operator"
	@echo "  make update-bundle  - Update bundle (VERSION=3.2.1 SOURCE=redhat)"
	@echo "  make list-versions  - List available bundle versions"
	@echo "  make test           - Run all tests"
	@echo "  make test-operator  - Test operator deployment"
	@echo "  make test-crd       - Test CRDs are installed"
	@echo "  make test-injection - Test sidecar injection"
	@echo "  make clean          - Full cleanup including CRDs"

deploy: check-kubeconfig
	@echo "=== Deploying Sail Operator ==="
	helmfile apply
	@echo ""
	@echo "Waiting for operator to be ready..."
	@kubectl wait --for=condition=available deployment/servicemesh-operator3 -n $(NAMESPACE) --timeout=$(TIMEOUT)s
	@echo "=== Operator deployed ==="

undeploy: check-kubeconfig
	./scripts/cleanup.sh

update-bundle:
	./scripts/update-bundle.sh $(VERSION) $(SOURCE)

list-versions:
	@./scripts/list-versions.sh

test: test-operator test-crd
	@echo ""
	@echo "========================================"
	@echo "  ALL TESTS PASSED"
	@echo "========================================"

test-operator: check-kubeconfig
	@./test/run-operator-test.sh

test-crd: check-kubeconfig
	@./test/run-crd-test.sh

test-injection: check-kubeconfig
	@./test/run-injection-test.sh

clean: check-kubeconfig
	./scripts/cleanup.sh --include-crds
