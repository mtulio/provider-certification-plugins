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
    #TARGET_RELEASES="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:-}" &&
    #TARGET_RELEASES=$(oc adm release info 4.11.13 -o jsonpath={.image})
    os_log_info "[executor] TARGET_RELEASES=${TARGET_RELEASES}"
    os_log_info "[executor] [upgrade] show current version:"
    oc get clusterversion

    TEST_UPGRADE_SUITE="none"
    ${UTIL_OTESTS_BIN} run-upgrade "${TEST_UPGRADE_SUITE}" \
        --to-image "${TARGET_RELEASES}" \
        --options "${TEST_UPGRADE_OPTIONS-}" \
        --junit-dir "${RESULTS_DIR}" \
        | tee -a "${RESULTS_PIPE}" &
    wait "$!" &&
    set +x
}

function upgrade_conformance() {
    local exit_code=0 &&
    run_upgrade || exit_code=$? &&
    PROGRESSING="$(oc get -o jsonpath='{.status.conditions[?(@.type == "Progressing")].status}' clusterversion version)" &&
    if test False = "${PROGRESSING}"
    then
        #TEST_LIMIT_START_TIME="$(date +%s)" TEST_SUITE="${CERT_TEST_SUITE}" suite || exit_code=$?
        echo "Upgrade_conformance have been finished, passing to the next plugin to run conformance."
    else
        echo "Skipping conformance suite because post-update ClusterVersion Progressing=${PROGRESSING}"
    fi &&
    return $exit_code
}


if [[ -n "${CERT_TEST_SUITE}" ]]; then
    os_log_info "Starting openshift-tests suite [${CERT_TEST_SUITE}] Provider Conformance executor..."

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
elif [[ "${PLUGIN_ID}" == "2" ]]; then

    if [[ "${RUN_MODE-}" == "upgrade" ]]; then
        upgrade_conformance
        # TODO: we must update openshift-tests binary after upgrade to make sure 
        # conformance plugins will run with updated binary

        # shellcheck disable=SC1091
        rm -f ${UTIL_OTESTS_BIN}
        start_utils_extractor
    else
        create_junit_with_msg "pass" "[opct][pass] ignoring upgrade mode."
    fi

# finalizer-collecting-artifacts
elif [[ "${PLUGIN_ID}" == "3" ]]; then

    cd ${RESULTS_DIR}
    oc adm must-gather
    tar cfJ artifacts_must-gather.tar.xz must-gather.local.*

    ${UTIL_OTESTS_BIN} run kubernetes/conformance --dry-run > ./artifacts_e2e-tests_kubernetes-conformance.txt
    ${UTIL_OTESTS_BIN} run openshift/conformance --dry-run > ./artifacts_e2e-openshift-conformance.txt

    tar cfz raw-results.tar.gz ./artifacts_*

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
    suite="${E2E_SUITE:-kubernetes/conformance}"
    os_log_info "Running default execution for openshift-tests suite [${suite}]..."
    ${UTIL_OTESTS_BIN} run \
        --junit-dir "${RESULTS_DIR}" \
        "${suite}" \
        | tee -a "${RESULTS_PIPE}" || true

    os_log_info "openshift-tests finished[$?]"
fi

os_log_info "Plugin executor finished. Result[$?]";
