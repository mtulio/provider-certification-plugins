#!/usr/bin/env bash

#
# openshift-tests-conformance (plugin)
#

set -o pipefail
set -o nounset
# set -o errexit

declare -gxr SERVICE_NAME="plugin"

# shellcheck disable=SC1091
source "$(dirname "$0")"/global_env.sh
# shellcheck disable=SC1091
source "$(dirname "$0")"/global_fn.sh

os_log_info "Starting plugin..."

create_dependencies_plugin

# Notify sonobuoy worker with e2e results (junit)
# https://github.com/vmware-tanzu/sonobuoy/blob/main/site/content/docs/main/plugins.md#plugin-result-types
sig_handler_save_results() {

    local junit_prefix
    local junit_output
    junit_prefix="junit"
    os_log_info "Saving results triggered. Slowing down..."
    sleep 5

    pushd "${RESULTS_DIR}" || exit 1

    # custom result by plugin
    ## artifacts-collector: raw
    if [[ "${PLUGIN_ID}" == "${PLUGIN_ID_OPENSHIFT_ARTIFACTS_COLLECTOR}" ]] || 
        [[ "${PLUGIN_ID}" == "${PLUGIN_ID_CONFORMANCE_EXTERNAL}" ]]; then
        echo "${RESULTS_DIR}/raw-results.tar.gz" > "${RESULTS_DONE_NOTIFY}"
        os_log_info "Results saved at ${RESULTS_DONE_NOTIFY}=[${RESULTS_DIR}/raw-results.tar.gz]";
        exit

    elif [[ "${PLUGIN_ID}" == "${PLUGIN_ID_OPENSHIFT_UPGRADE}" ]]; then
        # 'openshift-tests run-upgrade' generates 3 JUnits (2x junit_e2e_*.xml, 1x junit_upgrade_*.xml)
        # TODO: it's desired to collect all openshift-tests metadata.
        # To collect all metadata a few transformation should be done when discoverying the junits:
        # - 1) identify the junit responsible by the execution (to be used by Sonobuoy)
        # - 2) pack the metadata into tarball to avoid post-processor discoverying/processing files
        # - 3) change the result format to raw
        # - 4) send to aggregator the raw results
        # https://issues.redhat.com/browse/OPCT-33
        junit_prefix="junit_upgrade"
    fi

    # generic result file: JUnit
    os_log_info "Looking for junit result files..."
    mapfile -t JUNIT_FILES < <(ls ${junit_prefix}*.xml 2>/dev/null)
    os_log_info "JUnit files found=[${JUNIT_FILES[*]}]"

    # Create failed junit result file to avoid failures on report.
    # It could happened when executor has crashed.
    if [[ "${#JUNIT_FILES[*]}" -eq 0 ]]; then
        msg="[runner] default error handler: openshift-tests did not created JUnit file(s)"
        os_log_info "ERROR: ${msg}"
        create_junit_with_msg "failed" "[opct] ${msg}"
        junit_output=$(ls ${junit_prefix}*.xml);

    elif [[ "${#JUNIT_FILES[*]}" -gt 1 ]]; then
        os_log_info "More than one JUnit found=[${#JUNIT_FILES[*]}], using only ${JUNIT_FILES[0]}"
        junit_output=${JUNIT_FILES[0]}
    else
        junit_output=${JUNIT_FILES[0]}
    fi

    os_log_info "Adjusting permissions for results files."
    chmod 644 "${junit_output}";

    os_log_info "Sending plugin done to unlock report-progress"
    touch "${PLUGIN_DONE_NOTIFY}"

    os_log_info "Sending sonobuoy worker the result file path"
    echo "${RESULTS_DIR}/${junit_output}" > "${RESULTS_DONE_NOTIFY}"

    popd || true;
    os_log_info "Results saved at ${RESULTS_DONE_NOTIFY}=[${RESULTS_DIR}/${junit_output}]";
}
trap sig_handler_save_results EXIT

os_log_info "logging to the cluster..."
openshift_login

os_log_info "starting preflight checks..."
preflight_check_upgrade

os_log_info "starting sonobuoy status scraper..."
start_status_collector &

os_log_info "starting utilities extractor..."
start_utils_extractor &

os_log_info "initializing plugin config..."
init_config
show_config

os_log_info "check and wait for dependencies..."
wait_status_file
wait_utils_extractor

os_log_info "updating runtime configuration..."
update_config

os_log_info "starting waiter..."
"$(dirname "$0")"/wait-plugin.sh

# Force to update the utilities after cluster upgrades.
# It's mandatory to avoid running clusters with old e2e binaries.
if [[ "${RUN_MODE:-''}" == "${PLUGIN_RUN_MODE_UPGRADE}" ]]; then
    if [[ "${PLUGIN_ID}" != "${PLUGIN_ID_OPENSHIFT_UPGRADE}" ]]; then
        os_log_info "starting utilities extractor updater..."
        start_utils_extractor
    else
        os_log_info "ignoring extractor updater: ${PLUGIN_ID:-''}==${PLUGIN_ID_OPENSHIFT_UPGRADE}"
    fi
else
    os_log_info "ignoring extractor updater: ${RUN_MODE:-''}!=${PLUGIN_RUN_MODE_UPGRADE}"
fi

os_log_info "starting executor..."
"$(dirname "$0")"/executor.sh #| tee -a ${results_script_dir}/executor.log

# TODO(report): add a post processor of JUnit to identify flakes
# https://github.com/mtulio/openshift-provider-certification/issues/14

os_log_info "Plugin finished. Result[$?]";
