#!/usr/bin/env bash

os_log_info() {
    echo "#$(caller |awk '{print$2":"$1}')> " "$@"
}
export -f os_log_info

sys_sig_handler_error(){
    os_log_info "[signal handler] ERROR on line $(caller)" >&2
}
trap sys_sig_handler_error ERR

sys_sig_handler_term() {
    os_log_info "[signal handler] TERM signal received. Caller: $(caller)"
}
trap sys_sig_handler_term TERM

create_dependencies_plugin() {
    test -d "${RESULTS_SCRIPTS}" || mkdir -p "${RESULTS_SCRIPTS}"

    os_log_info_local "Creating results pipe to progress updater..."
    test -p "${RESULTS_PIPE}" || mkfifo "${RESULTS_PIPE}"
}

init_config() {
    os_log_info_local "[init_config]"
    if [[ -z "${CERT_LEVEL:-}" ]]
    then
        os_log_info_local "Empty CERT_LEVEL. It should be defined. Exiting..."
        exit 1

    os_log_info_local "Setting config for CERT_LEVEL=[${CERT_LEVEL:-}]..."
    elif [[ "${CERT_LEVEL:-}" == "0" ]]
    then
        PLUGIN_NAME="openshift-kube-conformance"
        CERT_TEST_FILE=""
        CERT_TEST_SUITE="kubernetes/conformance"
        PLUGIN_BLOCKED_BY=()

    elif [[ "${CERT_LEVEL:-}" == "1" ]]
    then
        PLUGIN_NAME="openshift-conformance-validated"
        CERT_TEST_FILE=""
        CERT_TEST_SUITE="openshift/conformance"
        PLUGIN_BLOCKED_BY+=("openshift-kube-conformance")

    elif [[ "${CERT_LEVEL:-}" == "2" ]]
    then
        PLUGIN_NAME="openshift-provider-cert-level2"
        CERT_TEST_FILE=""
        CERT_TEST_SUITE=""
        PLUGIN_BLOCKED_BY+=("openshift-conformance-validated")

    elif [[ "${CERT_LEVEL:-}" == "3" ]]
    then
        PLUGIN_NAME="openshift-provider-cert-level3"
        CERT_TEST_FILE=""
        CERT_TEST_SUITE=""
        PLUGIN_BLOCKED_BY+=("openshift-provider-cert-level2")

    else
        os_log_info "[init_config] Unknow value for CERT_LEVEL=[${CERT_LEVEL:-}]"
        exit 1
    fi

    os_log_info_local "Plugin Config: PLUGIN_NAME=[${PLUGIN_NAME:-}] PLUGIN_BLOCKED_BY=[${PLUGIN_BLOCKED_BY[*]}] CERT_TEST_FILE=[${CERT_TEST_FILE}]"


    os_log_info_local "Setup config done."
}
export -f init_config

update_config() {
    export CERT_TEST_COUNT=0
    if [[ -n "${CERT_TEST_FILE:-}" ]]; then
        CERT_TEST_COUNT="$(wc -l "${CERT_TEST_FILE}" |cut -f 1 -d' ' |tr -d '\n')"
    fi
    if [[ "${CERT_TEST_SUITE:-}" != "" ]]
    then
        CERT_TEST_COUNT="$(openshift-tests run --dry-run "${CERT_TEST_SUITE}" | wc -l)"
    fi
    os_log_info_local "Total tests was found: [${CERT_TEST_COUNT}]"
}

#
# openshift login
#

openshift_login() {
    os_log_info_local "[global] Trying to login to OpenShift cluster locally..."
    oc login "${KUBE_API_INT}" \
        --token="$(cat "${SA_TOKEN_PATH}")" \
        --certificate-authority="${SA_CA_PATH}" || true;

    os_log_info_local "[global] Discovering apiServerInternalURI..."
    INT_URI="$(oc get infrastructures cluster -o json | jq -r .status.apiServerInternalURI)"

    os_log_info_local "[global] Trying to login to OpenShift on internal URI [${INT_URI}]..."
    oc login "${INT_URI}" \
        --token="$(cat "${SA_TOKEN_PATH}")" \
        --certificate-authority="${SA_CA_PATH}" || true;
}

#
# Utilities extractor
#

# Extract utilities from internal image-registry
start_utils_extractor() {
    os_log_info_local "[utils_extractor] Starting..."
    local util_otests="./openshift-tests"

    os_log_info_local "[utils_extractor] Login to OpenShift Registry..."
    oc registry login

    os_log_info_local "[utils_extractor] Extracting openshift-tests utility..."
    oc image extract \
        image-registry.openshift-image-registry.svc:5000/openshift/tests:latest \
        --insecure=true \
        --file="${UTIL_OTESTS_BIN}"

    os_log_info_local "[utils_extractor] check if it was downloaded..."
    test -f ${util_otests} && chmod u+x ${util_otests}

    os_log_info_local "[utils_extractor] move to ${UTIL_OTESTS_BIN}..."
    mv ${util_otests} "${UTIL_OTESTS_BIN}"

    os_log_info_local "[utils_extractor] unlock extractor..."
    test -x "${UTIL_OTESTS_BIN}" && touch "${UTIL_OTESTS_READY}"
}

wait_utils_extractor() {
    os_log_info_local "[wait_utils_extractor] waiting for utils_extractor()..."
    while true;
    do
        os_log_info_local "Check if status file exists=[${UTIL_OTESTS_READY}]"
        test -f "${UTIL_OTESTS_READY}" && break
        sleep "${STATUS_UPDATE_INTERVAL_SEC}"
    done
    os_log_info_local "[global][wait_utils_extractor] finished!"
}

#
# Status scraper collects the results of Sonobuoy plugins
# The scraper will keep the status file STATUS_FILE consumed
# by different components on this container (waiter, progress reporter).
#
start_status_collector() {
    os_log_info_local "Starting sonobuoy status collector..."
    while true;
    do
        ${SONOBUOY_BIN} status -n "${ENV_POD_NAMESPACE:-sonobuoy}" --json 2>/dev/null > "${STATUS_FILE}"
        sleep "${STATUS_UPDATE_INTERVAL_SEC}"
    done
}
export -f start_status_collector

wait_status_file() {
    while true;
    do
        os_log_info_local "Check if status file exists=[${STATUS_FILE}]"
        test -f "${STATUS_FILE}" && break
        sleep "${STATUS_UPDATE_INTERVAL_SEC}"
    done
    os_log_info_local "Status file exists!"
}
export -f wait_status_file
