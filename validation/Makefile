# Makefile for LLMDXKXCheck

# Configurable settings
MAX_LINE_LENGTH ?= 120
CONTAINER_REPO ?= localhost/llmd-xks-checks
CONTAINER_TAG ?= latest
CONTAINER_TOOL ?= podman
HOST_KUBECONFIG ?= ~/.kube/config
FROM ?= registry.fedoraproject.org/fedora:latest

.PHONY: help test install uninstall lint pep8-fix

help:
	@echo "Available targets:"
	@echo "  container  Build a container image from the current directory"
	@echo "  run        Run the container image"
	@echo "  push       Push the container image to the container registry"
	@echo "  lint       Check code for PEP8 compliance"
	@echo "  pep8-fix   Automatically fix PEP8 compliance issues"
	@echo ""
	@echo "Configuration settings (all can be overridden by using environment variables):"
	@echo "  MAX_LINE_LENGTH=$(MAX_LINE_LENGTH) Python linter line length"
	@echo "  CONTAINER_REPO=$(CONTAINER_REPO) Container repository tag to use for build and run"
	@echo "  CONTAINER_TAG=$(CONTAINER_TAG) Container tag to use for build and run"
	@echo "  CONTAINER_TOOL=$(CONTAINER_TOOL) Container tool to use for build and run"
	@echo "  HOST_KUBECONFIG=$(HOST_KUBECONFIG) Path to kubeconfig for container run"


# Build a container image from the current directory
container:
	$(CONTAINER_TOOL) build --from $(FROM) --tag $(CONTAINER_REPO):$(CONTAINER_TAG) .

# Run the container image
run:
	$(CONTAINER_TOOL) run --rm -it --volume $(HOST_KUBECONFIG):/root/.kube/config:ro,Z $(CONTAINER_REPO):$(CONTAINER_TAG)

# Push the container image to the container registry
push:
	$(CONTAINER_TOOL) push $(CONTAINER_REPO):$(CONTAINER_TAG)

# Check code for PEP8 compliance
lint:
	flake8 --max-line-length=$(MAX_LINE_LENGTH) --exclude=build .

# Automatically fix PEP8 compliance issues
pep8-fix:
	autopep8 --max-line-length=$(MAX_LINE_LENGTH) --in-place --recursive .
