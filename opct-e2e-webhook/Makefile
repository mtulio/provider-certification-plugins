
IMG ?=  quay.io/opct/opct-e2e-webhook
VERSION ?= v0.0.0-devel
COMMIT ?= $(shell git rev-parse --short HEAD || true)
GO_BUILD_FLAGS ?= -ldflags "-s \
	-X github.com/redhat-openshift-ecosystem/provider-certification-plugins/opct-e2e-webhook/version.version=$(VERSION) \
	"
GOOS ?= linux
GOARCH ?= amd64
BINDIR := $(PWD)/bin
PLATFORMS ?= linux/amd64,linux/arm64

.PHONY: clean
clean:
	rm ./opct-e2e-webhook

.PHONY: build
build:
	@echo "Building opct-e2e-webhook"
	GOOS=$(GOOS) GOARCH=$(GOARCH) go build $(GO_BUILD_FLAGS) -o $(BINDIR)/opct-e2e-webhook . \
		&& strip $(BINDIR)/opct-e2e-webhook

.PHONY: build-image
build-image:
	podman manifest rm $(IMG):latest || true
	podman manifest create $(IMG):latest
	podman build --platform $(PLATFORMS) -f Containerfile --manifest $(IMG):latest .

.PHONY: push-image
push-image:
	podman manifest push $(IMG):latest

.PHONY: test
test:
	go test ./...
