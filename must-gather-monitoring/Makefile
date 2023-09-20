
CMD_CNT ?= podman
IMAGE_NAME ?= quay.io/opct/must-gather-monitoring
IMAGE_VERSION ?= $(shell git rev-parse --short HEAD)-$(shell date +%Y%m%d%H%M%S)

.PHONY: all
all: build-image

.PHONY: build-image
build-image:
	@echo "\n>> Build image: $(IMAGE_NAME):$(IMAGE_VERSION)"
	$(CMD_CNT) build -f Containerfile -t $(IMAGE_NAME):$(IMAGE_VERSION) .
	$(CMD_CNT) tag $(IMAGE_NAME):$(IMAGE_VERSION) $(IMAGE_NAME):devel
	$(CMD_CNT) push $(IMAGE_NAME):devel
	@echo "Build success! When you are ready to push:"
	@echo $(CMD_CNT) push $(IMAGE_NAME):$(IMAGE_VERSION)
	@echo "export IMG=$(IMAGE_NAME):$(IMAGE_VERSION)"
