.PHONY: deploy undeploy test test-selfsigned test-ca clean clean-tests update-bundle list-versions help check-kubeconfig

OPERATOR_NAMESPACE ?= cert-manager-operator
OPERAND_NAMESPACE ?= cert-manager
TIMEOUT ?= 180
VERSION ?= v1.15.2

export TEST_NAMESPACE = cert-manager-test
export TIMEOUT

check-kubeconfig:
	@kubectl cluster-info >/dev/null 2>&1 || (echo "ERROR: Cannot connect to cluster. Check KUBECONFIG is set and valid." && exit 1)

help:
	@echo "Usage:"
	@echo "  make deploy           - Deploy cert-manager operator (helmfile apply)"
	@echo "  make undeploy         - Remove cert-manager operator"
	@echo "  make update-bundle    - Update bundle (VERSION=v1.15.2)"
	@echo "  make test             - Run all tests"
	@echo "  make test-selfsigned  - Test self-signed certificate issuance"
	@echo "  make test-ca          - Test CA issuer and certificate chain"
	@echo "  make clean            - Full cleanup (operator + tests)"
	@echo "  make clean-tests      - Cleanup test resources only"

deploy: check-kubeconfig
	@echo "=== Deploying cert-manager Operator ==="
	helmfile apply
	@echo ""
	@echo "Waiting for operator to be ready..."
	@kubectl wait --for=condition=available deployment/cert-manager-operator-controller-manager -n $(OPERATOR_NAMESPACE) --timeout=$(TIMEOUT)s
	@echo ""
	@echo "Waiting for cert-manager components..."
	@sleep 10
	@kubectl wait --for=condition=available deployment/cert-manager -n $(OPERAND_NAMESPACE) --timeout=$(TIMEOUT)s
	@kubectl wait --for=condition=available deployment/cert-manager-webhook -n $(OPERAND_NAMESPACE) --timeout=$(TIMEOUT)s
	@kubectl wait --for=condition=available deployment/cert-manager-cainjector -n $(OPERAND_NAMESPACE) --timeout=$(TIMEOUT)s
	@echo ""
	@echo "=== cert-manager Operator deployed ==="
	@kubectl get pods -n $(OPERATOR_NAMESPACE)
	@kubectl get pods -n $(OPERAND_NAMESPACE)

undeploy: check-kubeconfig
	./scripts/cleanup.sh

update-bundle:
	./scripts/update-bundle.sh $(VERSION)

test: test-selfsigned test-ca
	@echo ""
	@echo "========================================"
	@echo "  ALL TESTS PASSED"
	@echo "========================================"

test-selfsigned: check-kubeconfig
	@./test/run-selfsigned-test.sh

test-ca: check-kubeconfig
	@./test/run-ca-test.sh

clean-tests: check-kubeconfig
	@echo "=== Cleaning up tests ==="
	-kubectl delete -f test/selfsigned-test.yaml --ignore-not-found 2>/dev/null
	-kubectl delete -f test/ca-test.yaml --ignore-not-found 2>/dev/null
	-kubectl delete namespace $(TEST_NAMESPACE) --ignore-not-found
	@echo "=== Tests cleaned up ==="

clean: clean-tests
	./scripts/cleanup.sh
