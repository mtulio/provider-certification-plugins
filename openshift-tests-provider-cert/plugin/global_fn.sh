#!/usr/bin/env bash

# Shared functions used across services

# os_log_info logger function, printing the current bash script
# and line as prefix.
os_log_info() {
    echo "$(date --iso-8601=seconds) | [${SERVICE_NAME}] | $(caller | awk '{print$2":"$1}')> " "$@"
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

    os_log_info "Creating results pipe to progress updater..."
    test -p "${RESULTS_PIPE}" || mkfifo "${RESULTS_PIPE}"
}

# init_config initializes the configuration based on variables sent
# to the pod. The plugin can assume different executions based on
# the intiial values defined on the variables PLUGIN_NAME, CERT_TEST_SUITE,
# and PLUGIN_BLOCKED_BY.
init_config() {
    os_log_info "[init_config] starting..."

    # Forcing to use newer CLI after plugin renaming
    if [[ -n "${CERT_LEVEL:-}" ]]
    then
        err="[init_config] Detected deprecated env var CERT_LEVEL. It can be caused by wrong CLI version. Please update the openshift-provider-cert binary and try again [CERT_LEVEL=${CERT_LEVEL:-}]"
        create_junit_with_msg "failed" "[opct] ${err}"
        os_log_info "${err}. Exiting..."
        exit 1
    fi

    if [[ -z "${PLUGIN_ID:-}" ]]
    then
        err="[init_config] Empty PLUGIN_ID[${PLUGIN_ID}]. PLUGIN_ID must be defined by Plugin manifest as env var"
        create_junit_with_msg "failed" "[opct] ${err}"
        os_log_info "${err}. Exiting..."
        exit 1
    fi

    os_log_info "Setting config for PLUGIN_ID=[${PLUGIN_ID:-}]..."
    if [[ "${PLUGIN_ID:-}" == "${PLUGIN_ID_OPENSHIFT_UPGRADE}" ]]
    then
        PLUGIN_NAME="${PLUGIN_NAME_OPENSHIFT_UPGRADE}"
        PLUGIN_BLOCKED_BY=()

    elif [[ "${PLUGIN_ID:-}" == "${PLUGIN_ID_KUBE_CONFORMANCE}" ]]
    then
        PLUGIN_NAME="${PLUGIN_NAME_KUBE_CONFORMANCE}"
        CERT_TEST_SUITE="${OPENSHIFT_TESTS_SUITE_KUBE_CONFORMANCE}"
        PLUGIN_BLOCKED_BY=("${PLUGIN_NAME_OPENSHIFT_UPGRADE}")

    elif [[ "${PLUGIN_ID:-}" == "${PLUGIN_ID_OPENSHIFT_CONFORMANCE}" ]]
    then
        PLUGIN_NAME="${PLUGIN_NAME_OPENSHIFT_CONFORMANCE}"
        CERT_TEST_SUITE="${OPENSHIFT_TESTS_SUITE_OPENSHIFT_CONFORMANCE}"
        PLUGIN_BLOCKED_BY+=("${PLUGIN_NAME_KUBE_CONFORMANCE}")

    elif [[ "${PLUGIN_ID:-}" == "${PLUGIN_ID_OPENSHIFT_ARTIFACTS_COLLECTOR}" ]]
    then
        PLUGIN_NAME="${PLUGIN_NAME_OPENSHIFT_ARTIFACTS_COLLECTOR}"
        PLUGIN_BLOCKED_BY+=("${PLUGIN_NAME_OPENSHIFT_CONFORMANCE}")

    else
        err="[init_config] Unknown value for PLUGIN_ID=[${PLUGIN_ID:-}]"
        create_junit_with_msg "failed" "[opct] ${err}"
        os_log_info "${err}. Exiting..."
        exit 1
    fi

    os_log_info "Plugin Config: PLUGIN_NAME=[${PLUGIN_NAME:-}] PLUGIN_BLOCKED_BY=[${PLUGIN_BLOCKED_BY[*]}] CERT_TEST_FILE=[${CERT_TEST_FILE}]"


    os_log_info "Setup config done."
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
CERT_LEVEL=${CERT_LEVEL:-''}
RUN_MODE=${RUN_MODE:-''}
UPGRADE_RELEASES=${UPGRADE_RELEASES-}
CERT_TEST_SUITE=${CERT_TEST_SUITE}
CERT_TEST_COUNT=${CERT_TEST_COUNT}
CERT_TEST_PARALLEL=${CERT_TEST_PARALLEL}
RESULTS_DIR=${RESULTS_DIR}
ENV_NODE_NAME=${ENV_NODE_NAME:-}
ENV_POD_NAME=${ENV_POD_NAME:-}
ENV_POD_NAMESPACE=${ENV_POD_NAMESPACE:-}
DEV_MODE_COUNT=${DEV_MODE_COUNT:-}
#> Config Dump [end] <#
#> Version INFO [start] <#
$(cat VERSION || true)
#> Version INFO [end]   <#
EOF
}

# update_config perform updates on configuration/environment variables
# not covered by init_config.
update_config() {
    os_log_info "[update_config] Getting the total tests to run"
    if [[ -n "${CERT_TEST_FILE:-}" ]]; then
        CERT_TEST_COUNT="$(wc -l "${CERT_TEST_FILE}" |cut -f 1 -d' ' |tr -d '\n')"
    fi
    if [[ "${CERT_TEST_SUITE:-}" != "" ]]
    then
        CERT_TEST_COUNT="$(${UTIL_OTESTS_BIN} run --dry-run "${CERT_TEST_SUITE}" | wc -l)"
    fi
    os_log_info "[update_config] Total tests found: [${CERT_TEST_COUNT}]"
}

#
# openshift login
#

# openshift_login perform the login on internal kube-apiserver. The credentials
# should be shared on the exported KUBECONFIG file.
openshift_login() {
    os_log_info "[login] Login to OpenShift cluster [${KUBE_API_INT}]"
    ${UTIL_OC_BIN} login "${KUBE_API_INT}" \
        --token="$(cat "${SA_TOKEN_PATH}")" \
        --certificate-authority="${SA_CA_PATH}" || true;

    os_log_info "[login] Discovering apiServerInternalURI"
    INT_URI="$(${UTIL_OC_BIN} get infrastructures cluster -o json | jq -r .status.apiServerInternalURI)"

    os_log_info "[login] Login to OpenShift cluster with internal URI [${INT_URI}]"
    ${UTIL_OC_BIN} login "${INT_URI}" \
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
    local junit_file_type
    local faliures_payload

    msg_type="$1"; shift
    msg="$1"; shift
    junit_file_type="${1:-e2e}"
    failures_count=0

    if [[ "${msg_type}" == "failed" ]]; then
        failures_count=1
        faliures_payload="<failure message=\"\">plugin runtime failed</failure><system-out></system-out>"
    fi
    junit_file="${RESULTS_DIR}/junit_${junit_file_type}_${msg_type}_$(date +%Y%m%d-%H%M%S).xml"

    os_log_info "Creating ${msg_type} JUnit result file [${junit_file}]"
    cat << EOF > "${junit_file}"
<testsuite name="openshift-tests" tests="1" skipped="0" failures="${failures_count}" time="1.0">
 <property name="TestVersion" value="v4.1.0"></property>
 <testcase name="${msg}" time="0"> ${faliures_payload:-''}
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
    os_log_info "[extractor_start] Starting"

    os_log_info "[extractor_start] Login to OpenShift Registry"
    ${UTIL_OC_BIN} registry login

    # Extracting oc (from tests image)
    local util_oc="./oc"
    os_log_info "[extractor_start][oc] Extracting oc utility from 'tests' image"
    ${UTIL_OC_BIN} image extract \
        image-registry.openshift-image-registry.svc:5000/openshift/tests:latest \
        --insecure=true \
        --file="/usr/bin/oc"

    os_log_info "[extractor_start][oc] check if it was downloaded"
    if [[ ! -f ${util_oc} ]]; then
        create_junit_with_msg "failed" "[opct][preflight] unable to extract oc utility. Check if image-registry is present."
        touch "${UTIL_OC_FAILED}"
        exit 1
    fi

    os_log_info "[extractor_start][oc] set exec permissions for ${UTIL_OC_BIN}"
    chmod u+x ${util_oc}
    if [[ ! -x ${UTIL_OC_BIN} ]]; then
        create_junit_with_msg "failed" "[opct][preflight] unable to make ${UTIL_OC_BIN} executable."
        touch "${UTIL_OC_FAILED}"
        exit 1
    fi

    os_log_info "[extractor_start][oc] move to ${UTIL_OC_BIN}"
    mv -f ${util_oc} "${UTIL_OC_BIN}"

    os_log_info "[extractor_start][oc] getting the version"
    ${UTIL_OC_BIN} version

    os_log_info "[extractor_start][oc] Success! Unlocking extractor"
    touch "${UTIL_OC_READY}"

    # Extracting openshift-tests
    local util_otests="./openshift-tests"
    os_log_info "[extractor_start][openshift-tests] Extracting the utility"
    ${UTIL_OC_BIN} image extract \
        image-registry.openshift-image-registry.svc:5000/openshift/tests:latest \
        --insecure=true \
        --file="/usr/bin/openshift-tests"

    os_log_info "[extractor_start][openshift-tests] check if it was downloaded"
    if [[ ! -f ${util_otests} ]]; then
        create_junit_with_msg "failed" "[opct][preflight][openshift-tests] unable to extract utility. Check if image-registry is present."
        touch "${UTIL_OTESTS_FAILED}"
        exit 1
    fi
    chmod u+x ${util_otests}

    os_log_info "[extractor_start][openshift-tests] move to ${UTIL_OTESTS_BIN}"
    mv ${util_otests} "${UTIL_OTESTS_BIN}"

    os_log_info "[extractor_start][openshift-tests] set exec permissions for ${UTIL_OTESTS_BIN}"
    if [[ ! -x ${UTIL_OTESTS_BIN} ]]; then
        create_junit_with_msg "failed" "[opct][preflight][openshift-tests] unable to make ${UTIL_OTESTS_BIN} executable."
        touch "${UTIL_OTESTS_FAILED}"
        exit 1
    fi

    os_log_info "[extractor_start][openshift-tests] testing openshift-tests"
    tt_tests=$(${UTIL_OTESTS_BIN} run all --dry-run | wc -l)
    if [[ ${tt_tests} -le 0 ]]; then
        create_junit_with_msg "failed" "[opct][preflight][openshift-tests] failed to get tests from ${UTIL_OTESTS_BIN} utility. Found [${tt_tests}] tests."
        touch "${UTIL_OTESTS_FAILED}"
        exit 1
    fi
    os_log_info "[extractor_start][openshift-tests] Success! [${tt_tests}] tests available."

    os_log_info "[extractor_start][openshift-tests] unlocking extractor"
    touch "${UTIL_OTESTS_READY}"
}
export -f start_utils_extractor

# wait_utils_extractor waits the UTIL_OTESTS_READY control file to be created,
# it will be ready when the openshift-tests is extracted from internal registry,
# controller by start_utils_extractor().
wait_utils_extractor() {
    os_log_info "[extractor_wait][oc] waiting for utils_extractor()"
    while true;
    do
        os_log_info "[extractor_wait][oc] Check files exists=[${UTIL_OC_READY} ${UTIL_OC_FAILED}]"
        test -f "${UTIL_OC_READY}" && break
        test -f "${UTIL_OC_FAILED}" && exit 1
        sleep "${STATUS_UPDATE_INTERVAL_SEC}"
    done
    os_log_info "[extractor_wait][oc] finished!"

    os_log_info "[extractor_wait][openshift-tests] waiting for utils_extractor()"
    while true;
    do
        os_log_info "[extractor_wait][openshift-tests] Check files exists=[${UTIL_OTESTS_READY} ${UTIL_OTESTS_FAILED}]"
        test -f "${UTIL_OTESTS_READY}" && break
        test -f "${UTIL_OTESTS_FAILED}" && exit 1
        sleep "${STATUS_UPDATE_INTERVAL_SEC}"
    done
    os_log_info "[extractor_wait][openshift-tests] finished!"
}


# start_status_collector collects the results of Sonobuoy plugins.
# The scraper will keep the status file STATUS_FILE consumed
# by different components on this container (waiter, progress reporter).
start_status_collector() {
    os_log_info "[status_collector] Starting"
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
    os_log_info "[status_file] Starting"
    while true;
    do
        os_log_info "[status_file] Check file exists=[${STATUS_FILE}]"
        test -f "${STATUS_FILE}" && break
        sleep "${STATUS_UPDATE_INTERVAL_SEC}"
    done
    os_log_info "[status_file] Status file found!"
}
export -f wait_status_file

#
# Cluster 'Upgrade' feature
#

# Run preflight checks before the upgrade. The execution must fail
# when there is not MachineConfigPool named 'opct' on the cluster.
# Required on the documentation:
# https://github.com/redhat-openshift-ecosystem/provider-certification-tool/blob/main/docs/user.md#prerequisites
# https://issues.redhat.com/browse/OPCT-35
preflight_check_upgrade() {
    os_log_info "[preflight][upgrade] starting checks for 'upgrade'..."

    if [[ "${RUN_MODE:-''}" != "${PLUGIN_RUN_MODE_UPGRADE}" ]]; then
        os_log_info "[preflight][upgrade] ignoring checks as RUN_MODE!=upgrade [${PLUGIN_RUN_MODE_UPGRADE}]"
        touch "${CHECK_MCP_READY}"
        return
    fi

    if [[ "${PLUGIN_ID}" == "${PLUGIN_ID_OPENSHIFT_ARTIFACTS_COLLECTOR}" ]]; then
        os_log_info "[preflight][upgrade] check for PLUGIN_ID=${PLUGIN_ID_OPENSHIFT_ARTIFACTS_COLLECTOR}"
        touch "${CHECK_MCP_READY}"
        return
    fi

    os_log_info "[preflight][upgrade] check MachineConfigPool 'opct' exists"
    ${UTIL_OC_BIN} get machineconfigpool opct
    RC_MCP=$?
    if [[ ${RC_MCP} -ne 0 ]]; then
        err="MachineConfigPool opct not found. Return code=${RC_MCP}"
        create_junit_with_msg "failed" "[opct][mode=${PLUGIN_RUN_MODE_UPGRADE}] ${err}" "upgrade"
        os_log_info "[executor] ${err}. Exiting..."
        touch "${CHECK_MCP_FAILED}"
        exit 1
    fi
    touch "${CHECK_MCP_READY}"
}
export -f preflight_check_upgrade

# Wait for check file for MCP
# https://issues.redhat.com/browse/OPCT-35
preflight_check_upgrade_waiter() {
    os_log_info "[preflight_check][upgrade-waiter] waiting for MachineConfigPool check"
    while true;
    do
        os_log_info "[preflight_check][upgrade-waiter] Check files exists=[${CHECK_MCP_READY} ${CHECK_MCP_FAILED}]"
        test -f "${CHECK_MCP_READY}" && break
        test -f "${CHECK_MCP_FAILED}" && exit 1
        sleep "${STATUS_UPDATE_INTERVAL_SEC}"
    done
    os_log_info "[preflight_check][upgrade-waiter] finished!"
}
export -f preflight_check_upgrade_waiter
