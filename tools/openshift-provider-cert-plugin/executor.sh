#!/usr/bin/env bash

#
# openshift-tests-partner-cert runner
#

#TODO(mtulio): pipefail should be commented until we provide a better solution
# to handle errors (failed e2e) on sub-process managed by openshift-tests main proc.
# https://issues.redhat.com/browse/SPLAT-592
#set -o pipefail
set -o nounset
# set -o errexit

os_log_info "[executor] Starting..."

os_log_info "[executor] Checking if credentials are present..."
test ! -f "${SA_CA_PATH}" || os_log_info "[executor] secret not found=${SA_CA_PATH}"
test ! -f "${SA_TOKEN_PATH}" || os_log_info "[executor] secret not found=${SA_TOKEN_PATH}"

#
# Executor options
#
os_log_info "[executor] Executor started. Choosing execution type based on environment sets."

if [[ -n "${CERT_TEST_SUITE}" ]]; then
    os_log_info "Running openshift-tests suite [${CERT_TEST_SUITE}] Provider Conformance..."
    #openshift-tests run \
    #    --junit-dir "${RESULTS_DIR}" \
    #    "${CERT_TEST_SUITE}" \
    #    | tee -a "${RESULTS_PIPE}" || true

    os_log_info "openshift-tests finished[$?]"

elif [[ "${CERT_LEVEL}" == "csi" ]]; then
    suite="openshift/csi"
    os_log_info "Starting setup CSI certification..."

    os_log_info "Getting CSI driver configuration from ConfigMap"
    os_log_info " Namespace[openshift-provider-certification-csi] ConfigMap[driver-test-spec] Key=[manifest.yaml]"
    oc extract configmap/driver-test-spec \
        -n openshift-provider-certification-csi \
        --keys=manifest.yaml

    os_log_info "Getting StorageClass [${STORAGE_CLASS:-}] manifest"
    oc get "storageclass/${STORAGE_CLASS:-}" -o yaml > cert-csi-storageclass.yaml

    os_log_info "Running openshift-tests suite [${suite}] for CSI Certification..."
    TEST_CSI_DRIVER_FILES=${PWD}/manifest.yaml openshift-tests run \
        --junit-dir "${RESULTS_DIR}" \
        "${suite}" \
        | tee -a "${RESULTS_PIPE}" || true

    os_log_info "openshift-tests finished for csi cert[$?]"

# To run custom tests, set the environment CERT_LEVEL on plugin definition.
# To generate the test file, use the script hack/generate-tests-tiers.sh
elif [[ -n "${CERT_TEST_FILE:-}" ]]; then
    os_log_info "Running openshift-tests for custom tests [${CERT_TEST_FILE}]..."
    if [[ -s ${CERT_TEST_FILE} ]]; then
        openshift-tests run \
            --junit-dir "${RESULTS_DIR}" \
            -f "${CERT_TEST_FILE}" \
            | tee -a "${RESULTS_PIPE}" || true
        os_log_info "openshift-tests finished[$?]"
    else
        os_log_info "the file provided has no tests. Sending progress and finish executor...";
        echo "(0/0/0)" > "${RESULTS_PIPE}"
        create_junit_with_msg "empty" "[conformance] empty test list: ${CERT_TEST_FILE} has no tests to run"
    fi

# Filter by string pattern from 'all' tests
elif [[ -n "${CUSTOM_TEST_FILTER_STR:-}" ]]; then
    os_log_info "Generating a filter [${CUSTOM_TEST_FILTER_STR}]..."
    openshift-tests run --dry-run all \
        | grep "${CUSTOM_TEST_FILTER_STR}" \
        | openshift-tests run -f - \
        | tee -a "${RESULTS_PIPE}" || true

# Default execution - running default suite.
# Set E2E_SUITE on plugin manifest to change it (unset CERT_LEVEL).
else
    suite="${E2E_SUITE:-kubernetes/conformance}"
    os_log_info "Running default execution for openshift-tests suite [${suite}]..."
    #TODO: Improve the visibility when this execution fails. Options:
    # - Save the stdout to a custom file
    # - Create a custom Junit file w/ failed test, and details about the
    #   failures. Maybe the entire b64 of stdout as failure description field.
    openshift-tests run \
        --junit-dir "${RESULTS_DIR}" \
        "${suite}" \
        | tee -a "${RESULTS_PIPE}" || true

    os_log_info "openshift-tests finished[$?]"
fi

os_log_info "Plugin executor finished. Result[$?]";
