#!/usr/bin/env bash

# os_log_info logger function, printing the current bash script
# and line as prefix.
os_log_info() {
    echo "#$(caller |awk '{print$2":"$1}')> " "$@"
}
export -f os_log_info

# sys_sig_handler_error handles the ERR sigspec.
sys_sig_handler_error(){
    os_log_info "[signal handler] ERROR on line $(caller)" >&2
}
trap sys_sig_handler_error ERR

# sys_sig_handler_term handles the TERM(15) sigspec.
sys_sig_handler_term() {
    os_log_info "[signal handler] TERM signal received. Caller: $(caller)"
}
trap sys_sig_handler_term TERM

# create_dependencies_plugin creates any initial dependency to run the plugin.
create_dependencies_plugin() {
    test -d "${SHARED_DIR}" || mkdir -p "${SHARED_DIR}"
    test -d "${RESULTS_SCRIPTS}" || mkdir -p "${RESULTS_SCRIPTS}"

    os_log_info_local "Creating results pipe to progress updater..."
    test -p "${RESULTS_PIPE}" || mkfifo "${RESULTS_PIPE}"
}

# init_config initializes the configuration based on variables sent
# to the pod. The plugin can assume different executions based on
# the intiial values defined on the variables PLUGIN_NAME, CERT_TEST_SUITE,
# and PLUGIN_BLOCKED_BY.
init_config() {
    os_log_info_local "[init_config]"
    if [[ -z "${PLUGIN_ID:-}" ]]
    then
        os_log_info_local "Empty PLUGIN_ID. It should be defined. Exiting..."
        exit 1
    fi

    os_log_info_local "Setting config for PLUGIN_ID=[${PLUGIN_ID:-}]..."
    if [[ "${PLUGIN_ID:-}" == "0" ]]
    then
        PLUGIN_NAME="10-openshift-kube-conformance"
        CERT_TEST_SUITE="kubernetes/conformance"
        PLUGIN_BLOCKED_BY=("01-openshift-cluster-upgrade")

    elif [[ "${PLUGIN_ID:-}" == "1" ]]
    then
        PLUGIN_NAME="20-openshift-conformance-validated"
        CERT_TEST_SUITE="openshift/conformance"
        PLUGIN_BLOCKED_BY+=("10-openshift-kube-conformance")

    elif [[ "${PLUGIN_ID:-}" == "2" ]]
    then
        PLUGIN_NAME="01-openshift-cluster-upgrade"
        PLUGIN_BLOCKED_BY=()
        RUN_MODE="upgrade"

    elif [[ "${PLUGIN_ID:-}" == "3" ]]
    then
        PLUGIN_NAME="99-openshift-artifacts-collector"
        PLUGIN_BLOCKED_BY=("20-openshift-conformance-validated")

    else
        os_log_info "[init_config] Unknow value for PLUGIN_ID=[${PLUGIN_ID:-}]"
        exit 1
    fi

    os_log_info_local "Plugin Config: PLUGIN_NAME=[${PLUGIN_NAME:-}] PLUGIN_BLOCKED_BY=[${PLUGIN_BLOCKED_BY[*]}] CERT_TEST_FILE=[${CERT_TEST_FILE}]"


    os_log_info_local "Setup config done."
}
export -f init_config

# show_config dump current configuration to stdout/logs, which will be collected
# on the tarball by aggregator.
show_config() {
    cat <<-EOF
#> Config Dump [start] <#
PLUGIN_NAME=${PLUGIN_NAME}
PLUGIN_BLOCKED_BY=${PLUGIN_BLOCKED_BY[*]}
PLUGIN_ID=${PLUGIN_ID}
RUN_MODE=${RUN_MODE}
TARGET_RELEASES=${TARGET_RELEASES-}
CERT_TEST_SUITE=${CERT_TEST_SUITE}
CERT_TEST_COUNT=${CERT_TEST_COUNT}
CERT_TEST_PARALLEL=${CERT_TEST_PARALLEL}
RESULTS_DIR=${RESULTS_DIR}
#> Config Dump [end] <#
#> Version INFO [start] <#
$(cat VERSION || true)
#> Version INFO [end]   <#
EOF
}

# update_config perform updates on configuration/environment variables
# not covered by init_config.
update_config() {
    os_log_info_local "[update_config] Getting the total tests to run"
    if [[ -n "${CERT_TEST_FILE:-}" ]]; then
        CERT_TEST_COUNT="$(wc -l "${CERT_TEST_FILE}" |cut -f 1 -d' ' |tr -d '\n')"
    fi
    if [[ "${CERT_TEST_SUITE:-}" != "" ]]
    then
        CERT_TEST_COUNT="$(${UTIL_OTESTS_BIN} run --dry-run "${CERT_TEST_SUITE}" | wc -l)"
    fi
    os_log_info_local "[update_config] Total tests found: [${CERT_TEST_COUNT}]"
}

#
# openshift login
#

# openshift_login perform the login on internal kube-apiserver. The credentials
# should be shared on the exported KUBECONFIG file.
openshift_login() {
    os_log_info_local "[login] Login to OpenShift cluster [${KUBE_API_INT}]"
    oc login "${KUBE_API_INT}" \
        --token="$(cat "${SA_TOKEN_PATH}")" \
        --certificate-authority="${SA_CA_PATH}" || true;

    os_log_info_local "[login] Discovering apiServerInternalURI"
    INT_URI="$(oc get infrastructures cluster -o json | jq -r .status.apiServerInternalURI)"

    os_log_info_local "[login] Login to OpenShift cluster with internal URI [${INT_URI}]"
    oc login "${INT_URI}" \
        --token="$(cat "${SA_TOKEN_PATH}")" \
        --certificate-authority="${SA_CA_PATH}" || true;
}

#
# JUnit utils
#

# create_junit_with_msg creates a "fake" JUnit result file with a custom message
# with reason, to help on the user feedback.
create_junit_with_msg() {
    local msg_type
    local msg
    local failures_count
    local junit_file

    msg_type="$1"; shift
    msg="$1"; shift
    failures_count=0

    if [[ "${msg_type}" == "failed" ]]; then
        failures_count=1
    fi
    junit_file="${RESULTS_DIR}/junit_${msg_type}_e2e_$(date +%Y%m%d-%H%M%S).xml"

    os_log_info_local "Creating ${msg_type} JUnit result file [${junit_file}]"
    cat << EOF > "${junit_file}"
<testsuite name="openshift-tests" tests="1" skipped="0" failures="${failures_count}" time="1.0">
 <property name="TestVersion" value="v4.1.0"></property>
 <testcase
    name="${msg}"
    time="1.0">
</testcase>
</testsuite>
EOF
    chmod 644 "${junit_file}"
}
export -f create_junit_with_msg

#
# Utilities extractor
#

# start_utils_extractor extracts the openshift-tests utility
# from local registry - the image-registry is required, the CLI
# checks it before calling the plugin.
start_utils_extractor() {
    os_log_info_local "[extractor_start] Starting"
    local util_otests="./openshift-tests"

    os_log_info_local "[extractor_start] Login to OpenShift Registry"
    oc registry login

    os_log_info_local "[extractor_start] Extracting openshift-tests utility"
    oc image extract \
        image-registry.openshift-image-registry.svc:5000/openshift/tests:latest \
        --insecure=true \
        --file="/usr/bin/openshift-tests"

    os_log_info_local "[extractor_start] check if it was downloaded"
    if [[ ! -f ${util_otests} ]]; then
        create_junit_with_msg "fail" "[fail][preflight] unable to extract openshift-tests utility. Check if image-registry is present."
        touch "${UTIL_OTESTS_FAILED}"
        exit 1
    fi
    chmod u+x ${util_otests}

    os_log_info_local "[extractor_start] move to ${UTIL_OTESTS_BIN}"
    mv ${util_otests} "${UTIL_OTESTS_BIN}"

    os_log_info_local "[extractor_start] set exec permissions for ${UTIL_OTESTS_BIN}"
    if [[ ! -x ${UTIL_OTESTS_BIN} ]]; then
        create_junit_with_msg "fail" "[fail][preflight] unable to make ${UTIL_OTESTS_BIN} executable."
        touch "${UTIL_OTESTS_FAILED}"
        exit 1
    fi

    os_log_info_local "[extractor_start] testing openshift-tests"
    tt_tests=$(${UTIL_OTESTS_BIN} run all --dry-run | wc -l)
    if [[ ${tt_tests} -le 0 ]]; then
        create_junit_with_msg "fail" "[fail][preflight] failed to get tests from ${UTIL_OTESTS_BIN} utility. Found [${tt_tests}] tests."
        touch "${UTIL_OTESTS_FAILED}"
        exit 1
    fi
    os_log_info_local "[extractor_start] Success! openshift-tests has [${tt_tests}] tests available."

    os_log_info_local "[extractor_start] unlocking extractor"
    touch "${UTIL_OTESTS_READY}"
}
export -f start_utils_extractor

# wait_utils_extractor waits the UTIL_OTESTS_READY control file to be created,
# it will be ready when the openshift-tests is extracted from internal registry,
# controller by start_utils_extractor().
wait_utils_extractor() {
    os_log_info_local "[extractor_wait] waiting for utils_extractor()"
    while true;
    do
        os_log_info_local "[extractor_wait] Check files exists=[${UTIL_OTESTS_READY} ${UTIL_OTESTS_FAILED}]"
        test -f "${UTIL_OTESTS_READY}" && break
        test -f "${UTIL_OTESTS_FAILED}" && exit 1
        sleep "${STATUS_UPDATE_INTERVAL_SEC}"
    done
    os_log_info_local "[extractor_wait] finished!"
}


# start_status_collector collects the results of Sonobuoy plugins.
# The scraper will keep the status file STATUS_FILE consumed
# by different components on this container (waiter, progress reporter).
start_status_collector() {
    os_log_info_local "[status_collector] Starting"
    while true;
    do
        ${SONOBUOY_BIN} status \
            -n "${ENV_POD_NAMESPACE:-sonobuoy}" --json \
            2>/dev/null > "${STATUS_FILE}"
        sleep "${STATUS_UPDATE_INTERVAL_SEC}"
    done
}
export -f start_status_collector

# wait_status_file waits for STATUS_FILE be created by start_status_collector()
# blocking the execution until this file is created.
wait_status_file() {
    os_log_info_local "[status_file] Starting"
    while true;
    do
        os_log_info_local "[status_file] Check file exists=[${STATUS_FILE}]"
        test -f "${STATUS_FILE}" && break
        sleep "${STATUS_UPDATE_INTERVAL_SEC}"
    done
    os_log_info_local "[status_file] Status file found!"
}
export -f wait_status_file
