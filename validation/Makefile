# Configurable settings
CONTAINER_REPO ?= localhost/llmd-xks-checks
CONTAINER_TAG ?= latest
CONTAINER_TOOL ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)
HOST_KUBECONFIG ?= ~/.kube/config

# SUITE can be set to "cluster" or "operators", defaults to "all"
SUITE ?= all

# SELinux label for volume mounts (only needed for podman)
VOLUME_OPTS ?= $(shell [ "$(CONTAINER_TOOL)" = "podman" ] && echo ":ro,Z" || echo ":ro")

# CONFIG can be set to a config file path to mount into the container
CONFIG ?=
# Config mount and argument (only if CONFIG is set)
CONFIG_MOUNT ?= $(if $(CONFIG),--volume $(CONFIG):/tmp/config.conf$(VOLUME_OPTS),)
CONFIG_ARG ?= $(if $(CONFIG),--config /tmp/config.conf,)

.PHONY: help image run push lint pep8-fix

help:
	@echo "Available targets:"
	@echo "  image         Build a container image from the current directory"
	@echo "  run           Run the image with tests (use SUITE=cluster|operators|all)"
	@echo "  push          Push the image to the container registry"
	@echo "  lint          Check code for PEP8 compliance"
	@echo "  pep8-fix      Automatically fix PEP8 compliance issues"
	@echo ""
	@echo "Configuration settings (all can be overridden by using environment variables):"
	@echo "  CONTAINER_REPO=$(CONTAINER_REPO) Container repository tag to use for build and run"
	@echo "  CONTAINER_TAG=$(CONTAINER_TAG) Container tag to use for build and run"
	@echo "  CONTAINER_TOOL=$(CONTAINER_TOOL) Container tool to use for build and run"
	@echo "  HOST_KUBECONFIG=$(HOST_KUBECONFIG) Path to kubeconfig for container run"
	@echo "  SUITE=$(SUITE) Test suite to run (all, cluster, operators)"
	@echo "  CONFIG=$(CONFIG) Path to config file to mount into the container"


# Build a container image from the current directory
image:
	$(CONTAINER_TOOL) build --tag $(CONTAINER_REPO):$(CONTAINER_TAG) .

# Run the container image with tests
run:
	$(CONTAINER_TOOL) run --rm -it --volume $(HOST_KUBECONFIG):/tmp/kubeconfig$(VOLUME_OPTS) $(CONFIG_MOUNT) -e KUBECONFIG=/tmp/kubeconfig $(CONTAINER_REPO):$(CONTAINER_TAG) -s $(SUITE) $(CONFIG_ARG)


# Push the container image to the container registry
push:
	$(CONTAINER_TOOL) push $(CONTAINER_REPO):$(CONTAINER_TAG)

# Linting settings
MAX_LINE_LENGTH ?= 120

# Check code for PEP8 compliance
lint:
	@command -v flake8 >/dev/null 2>&1 || pip install flake8
	flake8 --max-line-length=$(MAX_LINE_LENGTH) --exclude=build .

# Automatically fix PEP8 compliance issues
pep8-fix:
	@command -v autopep8 >/dev/null 2>&1 || pip install autopep8
	autopep8 --max-line-length=$(MAX_LINE_LENGTH) --in-place --recursive .
