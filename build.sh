#!/usr/bin/env bash

# Build OPCT plugin images.

set -o pipefail
set -o nounset
set -o errexit

COMMAND=${1}; shift
BUILD_IMG=${1}; shift
PLATFORMS=${1:-linux/amd64,linux/arm64};

# shellcheck disable=SC1091
source "$(dirname "$0")/build.env"

function push_image() {
    img_name=$1
    if [[ $COMMAND == "push" ]]; then
        podman push "${img_name}";
    fi
}

function build_tools() {
    local build_root
    build_root=$(dirname "$0")/tools
    echo "${TOOLS_VERSION}" > "${build_root}"/VERSION
    img_name="${TOOLS_IMG}"
    manifest="quay.io/opct/tools:${MGM_VERSION}"

    echo "Removing manifest ${manifest} if exists..."
    podman manifest rm "${manifest}" || true

    echo "Creating manifests..."
    podman manifest create "${manifest}"

    echo -e "\n\n\t>> Building ${manifest}\n"
    for platform in $(echo "${PLATFORMS}" | tr ',' ' '); do
        echo -e "\n\n\t>> Building ${manifest} for ${platform}\n"
        TARGET_OS=$(echo "${platform}" | cut -d'/' -f1)
        TARGET_ARCH=$(echo "${platform}" | cut -d'/' -f2)
        BUILD_ARCH="$TARGET_OS-$TARGET_ARCH"

        jq_bin="jq-${BUILD_ARCH}"
        jq_url="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/${jq_bin}"

        yq_bin="yq_${TARGET_OS}_${TARGET_ARCH}"
        yq_url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${yq_bin}"

        # TODO: build CAMGI in other supported arches.
        # https://issues.redhat.com/browse/OPCT-275
        camgi_archive="camgi-0.9.0-linux-x86_64.tar"
        camgi_url="https://github.com/elmiko/camgi.rs/releases/download/v0.9.0/${camgi_archive}"

        ocp_version="stable-4.16"
        oc_archive="openshift-client-linux.tar.gz"
        oc_url="https://mirror.openshift.com/pub/openshift-v4/${TARGET_ARCH}/clients/ocp/${ocp_version}/${oc_archive}"

        podman build --platform "${platform}" \
            --manifest "${manifest}" \
            -f "${build_root}"/Containerfile \
            --build-arg=JQ_URL="${jq_url}" \
            --build-arg=JQ_BIN="${jq_bin}" \
            --build-arg=YQ_URL="${yq_url}" \
            --build-arg=YQ_BIN="${yq_bin}" \
            --build-arg=CAMGI_URL="${camgi_url}" \
            --build-arg=CAMGI_TAR="${camgi_archive}" \
            --build-arg=OC_TAR="${oc_archive}" \
            --build-arg=OC_URL="${oc_url}" \
            --build-arg=SONOBUOY_VERSION="${SONOBUOY_VERSION}" \
            --build-arg=QUAY_EXPIRATION="${IMAGE_EXPIRE_TIME}" \
            --build-arg=TARGETPLATFORM="${platform}" \
            --build-arg=TARGETARCH="${TARGET_ARCH}" \
            --build-arg=TARGETOS="${TARGET_OS}" \
            -t "${img_name}-${TARGET_OS}-${TARGET_ARCH}" "${build_root}"
    done

    if [[ "$COMMAND" == "push" ]]; then
        echo -e "\n\tPushing manifest ${manifest}...\n\n"
        podman manifest push "${manifest}" || true
    fi
}

function build_plugin_tests() {
    build_root=$(dirname "$0")/openshift-tests-provider-cert
    echo "${PLUGIN_TESTS_VERSION}" > "${build_root}"/VERSION
    img_name="${PLUGIN_TESTS_IMG}"
    manifest="quay.io/opct/plugin-openshift-tests:${MGM_VERSION}"

    echo "Removing manifest ${manifest} if exists..."
    podman manifest rm "${manifest}" || true

    echo "Creating manifests..."
    podman manifest create "${manifest}"

    echo -e "\n\n\t>> Building ${manifest}\n"
    podman build -f "${build_root}"/Containerfile \
        --platform "${PLATFORMS}" \
        --manifest "${manifest}" \
        --build-arg=TOOLS_IMG="${TOOLS_IMG}" \
        --build-arg=QUAY_EXPIRATION="${IMAGE_EXPIRE_TIME}" \
        -t "${img_name}-buildx" "${build_root}"

    if [[ "$COMMAND" == "push" ]]; then
        echo -e "\n\tPushing manifest ${manifest}...\n\n"
        podman manifest push "${manifest}" || true
    fi
}

function build_mgm() {
    build_root=$(dirname "$0")/must-gather-monitoring

    echo "${MGM_VERSION}" > "${build_root}"/VERSION
    img_name="${MGM_IMG}"
    manifest="quay.io/opct/must-gather-monitoring:${MGM_VERSION}"

    echo "Removing manifest ${manifest} if exists..."
    podman manifest rm "${manifest}" || true

    echo "Creating manifests..."
    podman manifest create "${manifest}"

    echo -e "\n\n\t>> Building ${manifest}\n"
    podman build -f "${build_root}"/Containerfile \
        --platform "${PLATFORMS}" \
        --manifest "${manifest}" \
        --build-arg=TOOLS_IMG="${TOOLS_IMG}" \
        --build-arg=QUAY_EXPIRATION="${IMAGE_EXPIRE_TIME}" \
        -t "${img_name}-buildx" "${build_root}"

    if [[ "$COMMAND" == "push" ]]; then
        echo -e "\n\tPushing manifest ${manifest}...\n\n"
        podman manifest push "${manifest}" || true
    fi
}

function help() {
    echo "WHAT/App not mapped to build: $BUILD_IMG";
    echo "Valid values:
make build WHAT=tools COMMAND=build ARCH=linux-amd64
make build WHAT=pugin-openshift-tests COMMAND=build ARCH=linux-amd64
make build WHAT=must-gather-monitoring COMMAND=build ARCH=linux-amd64"
    exit 1
}

case $BUILD_IMG in
    "tools") build_tools;;
    "plugin-openshift-tests") build_plugin_tests;;
    "must-gather-monitoring") build_mgm;;
    *) help;;
esac
