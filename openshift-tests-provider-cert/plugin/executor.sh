#!/usr/bin/env bash

#
# openshift-tests-partner-cert runner
#

#TODO(mtulio): pipefail should be commented until we provide a better solution
# to handle errors (failed e2e) on sub-process managed by openshift-tests main proc.
# https://issues.redhat.com/browse/SPLAT-592
#set -o pipefail
# set -o errexit
set -o nounset

os_log_info "[executor] Starting..."

os_log_info "[executor] Checking if credentials are present..."
test ! -f "${SA_CA_PATH}" || os_log_info "[executor] secret not found=${SA_CA_PATH}"
test ! -f "${SA_TOKEN_PATH}" || os_log_info "[executor] secret not found=${SA_TOKEN_PATH}"

#
# Executor options
#
os_log_info "[executor] Executor started. Choosing execution type based on environment sets."

run_upgrade() {
    set -x &&
    os_log_info "[executor] UPGRADE_RELEASES=${UPGRADE_RELEASES}"
    os_log_info "[executor] [upgrade] show current version:"
    oc get clusterversion

    TEST_UPGRADE_SUITE="none"
    ${UTIL_OTESTS_BIN} run-upgrade "${TEST_UPGRADE_SUITE}" \
        --to-image "${UPGRADE_RELEASES}" \
        --options "${TEST_UPGRADE_OPTIONS-}" \
        --junit-dir "${RESULTS_DIR}" \
        | tee -a "${RESULTS_PIPE}"
    set +x
}

# function scc_enable() {
#     # TODO fix scc: https://github.com/cncf/k8s-conformance/tree/master/v1.24/openshift#run-conformance-tests
#     os_log_info "[workaround/scc] Setting unprivileged users to run root level containers..."
#     oc adm policy add-scc-to-group privileged system:authenticated system:serviceaccounts || true
#     oc adm policy add-scc-to-group anyuid system:authenticated system:serviceaccounts || true
# }

# function scc_disable() {
#     # TODO fix scc: https://github.com/cncf/k8s-conformance/tree/master/v1.24/openshift#run-conformance-tests
#     os_log_info "[workaround/scc] Unsetting unprivileged users to run root level containers..."
#     oc adm policy remove-scc-from-group anyuid system:authenticated system:serviceaccounts || true
#     oc adm policy remove-scc-from-group privileged system:authenticated system:serviceaccounts || true
# }


if [[ -n "${CERT_TEST_SUITE}" ]]; then
    os_log_info "Starting openshift-tests suite [${CERT_TEST_SUITE}] Provider Conformance executor..."

    # TODO fix scc: https://github.com/cncf/k8s-conformance/tree/master/v1.24/openshift#run-conformance-tests
    # os_log_info_local "[workaround/scc] Setting unprivileged users to run root level containers..."
    # scc_enable
    # Always enable
    # scc_enable
    set -x
    ${UTIL_OTESTS_BIN} run \
        --max-parallel-tests "${CERT_TEST_PARALLEL}" \
        --junit-dir "${RESULTS_DIR}" \
        "${CERT_TEST_SUITE}" --dry-run \
        > "${RESULTS_DIR}/suite-${CERT_TEST_SUITE/\/}.list"

    os_log_info "Saving the test list on ${RESULTS_DIR}/suite-${CERT_TEST_SUITE/\/}.list"
    wc -l "${RESULTS_DIR}/suite-${CERT_TEST_SUITE/\/}.list"

    if [[ ${DEV_TESTS_COUNT} -gt 0 ]]; then
        os_log_info "DEV mode detected, applying filter to job count: [${DEV_TESTS_COUNT}]"
        shuf "${RESULTS_DIR}/suite-${CERT_TEST_SUITE/\/}.list" \
            | head -n "${DEV_TESTS_COUNT}" \
            > "${RESULTS_DIR}/suite-${CERT_TEST_SUITE/\/}-DEV.list"

        os_log_info "Saving the DEV test list on ${RESULTS_DIR}/suite-${CERT_TEST_SUITE/\/}-DEV.list"
        wc -l "${RESULTS_DIR}/suite-${CERT_TEST_SUITE/\/}-DEV.list"

        os_log_info "Running on DEV mode..."
        ${UTIL_OTESTS_BIN} run \
            --max-parallel-tests "${CERT_TEST_PARALLEL}" \
            --junit-dir "${RESULTS_DIR}" \
            -f "${RESULTS_DIR}/suite-${CERT_TEST_SUITE/\/}-DEV.list" \
            | tee -a "${RESULTS_PIPE}" || true

    else
        os_log_info "Running the test suite..."
        ${UTIL_OTESTS_BIN} run \
            --max-parallel-tests "${CERT_TEST_PARALLEL}" \
            --junit-dir "${RESULTS_DIR}" \
            "${CERT_TEST_SUITE}" \
            | tee -a "${RESULTS_PIPE}" || true
    fi

    os_log_info "openshift-tests finished[$?]"
    set +x

# run-upgrade tests
elif [[ "${PLUGIN_ID}" == "${PLUGIN_ID_OPENSHIFT_UPGRADE}" ]]; then

    if [[ "${RUN_MODE-}" == "upgrade" ]]; then
        PROGRESSING="$(oc get -o jsonpath='{.status.conditions[?(@.type == "Progressing")].status}' clusterversion version)"
        os_log_info "[executor] Running Plugin_ID ${PLUGIN_ID}, starting... Cluster is progressing? ${PROGRESSING}"

        run_upgrade

        PROGRESSING="$(oc get -o jsonpath='{.status.conditions[?(@.type == "Progressing")].status}' clusterversion version)"
        os_log_info "[executor] Running Plugin_ID ${PLUGIN_ID}. finished... Cluster is progressing? ${PROGRESSING}"

        os_log_info "[executor] Creating the raw results file ${RESULT_RAW_FILE_PATH}..."
        pushd "${RESULTS_DIR}" || true
        tar cfz "/tmp/${RESULT_RAW_FILE_NAME}" ./*
        mv "/tmp/${RESULT_RAW_FILE_NAME}" "${RESULT_RAW_FILE_PATH}"
        popd || true
    else
        create_junit_with_msg "pass" "[opct][pass] ignoring upgrade mode."
    fi

# finalizer-collecting-artifacts
elif [[ "${PLUGIN_ID}" == "${PLUGIN_ID_OPENSHIFT_ARTIFACTS}" ]]; then

    cd ${RESULTS_DIR}
    oc adm must-gather
    tar cfJ artifacts_must-gather.tar.xz must-gather.local.*

    ${UTIL_OTESTS_BIN} run kubernetes/conformance --dry-run > ./artifacts_e2e-tests_kubernetes-conformance.txt
    ${UTIL_OTESTS_BIN} run openshift/conformance --dry-run > ./artifacts_e2e-openshift-conformance.txt

    tar cfz "${RESULT_RAW_FILE_PATH}" ./artifacts_*

# To run custom tests, set the environment PLUGIN_ID on plugin definition.
# To generate the test file, use the script hack/generate-tests-tiers.sh
elif [[ -n "${CERT_TEST_FILE:-}" ]]; then
    os_log_info "Running openshift-tests for custom tests [${CERT_TEST_FILE}]..."
    if [[ -s ${CERT_TEST_FILE} ]]; then
        ${UTIL_OTESTS_BIN} run \
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
    ${UTIL_OTESTS_BIN} run --dry-run all \
        | grep "${CUSTOM_TEST_FILTER_STR}" \
        | ${UTIL_OTESTS_BIN} run -f - \
        | tee -a "${RESULTS_PIPE}" || true

# Default execution - running default suite.
# Set E2E_SUITE on plugin manifest to change it (unset PLUGIN_ID).
else
    suite="${E2E_SUITE:-${OPENSHIFT_TESTS_SUITE_KUBE_CONFORMANCE}}"
    os_log_info "Running default execution for openshift-tests suite [${suite}]..."
    ${UTIL_OTESTS_BIN} run \
        --junit-dir "${RESULTS_DIR}" \
        "${suite}" \
        | tee -a "${RESULTS_PIPE}" || true

    os_log_info "openshift-tests finished[$?]"
fi

os_log_info "Plugin executor finished. Result[$?]";
