#!/usr/bin/env bash

# Create multi-arch manifests for a given image

set -o pipefail
set -o nounset
set -o errexit

# shellcheck disable=SC1091
source "$(dirname "$0")"/../build.env

COMMAND=$1; shift
APP=$1;

case $APP in
    "tools") base_image=${TOOLS_IMG};;
    "plugin-openshift-tests") base_image=${PLUGIN_TESTS_IMG};;
    "must-gather-monitoring") base_image=${MGM_IMG};;
    *) echo "App not found: ${APP:-}"; exit 1;;
esac

export PLATFORM_IMAGES=""

# ensure image exists and is pulled to create manifests
for arch in ${!BUILD_PLATFORMS[*]}
do
    img=${base_image}-${arch}
    echo "Appending image to the list: ${img}"
    if ! podman image exists "${img}" ; then
        echo "Pulling image: ${img}"
        podman pull "${img}";
    fi
    PLATFORM_IMAGES+=" ${img}"
done

set -x

if podman manifest exists "${base_image}" ; then
    echo "Manifest already exists: ${base_image}"
    echo "Removing existing manifest: ${base_image}"
    podman manifest rm "${base_image}"
fi

echo "Creating manifest for [${base_image}] with iamges [${PLATFORM_IMAGES}]"
# shellcheck disable=SC2086
podman manifest create "${base_image}" ${PLATFORM_IMAGES}


if [[ "${COMMAND}" == "push" ]] ; then
    echo "Pushing manifest: ${base_image}"
    podman manifest push "${base_image}" docker://"${base_image}"
fi
