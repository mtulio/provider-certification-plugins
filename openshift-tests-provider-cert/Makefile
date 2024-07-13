
VERSION ?= $(shell date +%Y%m%d%H%M%S)
DEV_REGISTRY ?= quay.io/ocp-cert

all: build-ci
.PHONY: all

build-ci:
	hack/build-image.sh build-plugin
.PHONY: build-ci

build-dev:
	VERSION_DEVEL=devel REGISTRY_PLUGIN=$(DEV_REGISTRY) hack/build-image.sh build-dev
.PHONY: build-dev

.PHONY: release
release:
	VERSION_PLUGIN=$(VERSION) hack/build-image.sh release


.PHONY: test
test:
	hack/test_runner.sh

.PHONY: test-shellcheck
test-shellcheck:
	shellcheck plugin/*.sh hack/*.sh

