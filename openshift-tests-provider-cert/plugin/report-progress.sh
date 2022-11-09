#!/usr/bin/env bash

#
# openshift-tests-partner-cert plugin - progress reporter
# Send progress from openshift-tests execution to sonobuoy worker.
#

set -o pipefail
set -o nounset
set -o errexit

declare -gx PIDS_LOCAL
declare -gx PROGRESS

# shellcheck disable=SC1091
source "$(dirname "$0")"/global_env.sh
# shellcheck disable=SC1091
source "$(dirname "$0")"/global_fn.sh

os_log_info_local() {
    echo "$(date +%Y%m%d-%H%M%S)> [report] $*"
}

# wait_progress_api waits for sonobuoy worker is listening.
wait_progress_api() {
    local addr_ip
    local addr_port
    addr_ip=$(echo "${PROGRESS_URL}" |grep -Po '(\d+.\d+.\d+.\d+)')
    addr_port=$(echo "${PROGRESS_URL}" |grep -Po '\d{4}')

    os_log_info_local "waiting for sonobuoy-worker service is ready..."
    while true
    do
        test "$(echo '' | curl telnet://"${addr_ip}":"${addr_port}" >/dev/null 2>&1; echo $?)" -eq 0 && break
        sleep 1
    done
    os_log_info_local "sonobuoy-worker progress api[${PROGRESS_URL}] is ready."
}

# update_progress sends updates to the progress report API (worker).
update_progress() {
    # Reporting progress to sonobuoy progress API
    component_caller="${1:-"update_progress"}"; shift
    msg="${1:-"N/D"}"; shift || true
    body="{
        \"completed\":${PROGRESS["completed"]},
        \"total\":${PROGRESS["total"]},
        \"failures\":[${PROGRESS["failures"]}],
        \"msg\":\"${msg}\"
    }"
    os_log_info_local "Sending report payload [${component_caller}]: ${body}"
    curl -s "${PROGRESS_URL}" -d "${body}" || true
}

# wait_pipe_exists wait until the pipe file is created by plugin.
wait_pipe_exists() {
    os_log_info_local "waiting for pipe creation..."
    while true
    do
        test -p "${RESULTS_PIPE}" && break
        sleep 1
    done
    os_log_info "[report]  pipe[${RESULTS_PIPE}] created. Starting progress report"
}

# watch_plugin_done watches to block the plugin to be finished prematurely.
watch_plugin_done() {
    os_log_info_local "waiting for plugin done file..."
    while true; do
        if [[ -f "${PLUGIN_DONE_NOTIFY}" ]]
        then
            echo "Sonobuoy done detected [done wacther]" |tee -a "${RESULTS_PIPE}"
            return
        fi
        sleep 1
    done
    os_log_info_local "plugin done file detected!"
}

# watch_dependency_done watches aggregator API (status) to
# unblock the execution when dependencies was finished the execution.
watch_dependency_done() {
    os_log_info_local "[watch_dependency] Starting dependency check..."
    for plugin_name in "${PLUGIN_BLOCKED_BY[@]}"; do
        os_log_info_local "waiting for plugin [${plugin_name}]"
        timeout_checks=0
        timeout_count=100
        last_count=0
        while true;
        do
            if [[ -f "${PLUGIN_DONE_NOTIFY}" ]]
            then
                echo "[watch_dependency] Done file detected" |tee -a "${RESULTS_PIPE}"
                return
            fi

            plugin_status=$(jq -r ".plugins[] | select (.plugin == \"${plugin_name}\" ) |.status // \"\"" "${STATUS_FILE}")
            if [[ "${plugin_status}" == "complete" ]]; then
                echo "Plugin[${plugin_name}] with status[${plugin_status}] is completed!"
                break
            fi
            count=$(jq -r ".plugins[] | select (.plugin == \"${plugin_name}\" ) |.progress.completed // 0" "${STATUS_FILE}")
            total=$(jq -r ".plugins[] | select (.plugin == \"${plugin_name}\" ) |.progress.total // \"0\"" "${STATUS_FILE}")
            remaining=$(( total - count ))
            test $remaining -ge 0 && remaining=$(( (total - count) * (-1) ))

            blocker_msg=$(jq -r ".plugins[] | select (.plugin == \"${plugin_name}\" ) |.progress.msg // \"\"" "${STATUS_FILE}")
            # Dependency plugin is also waiting
            if [[ "${blocker_msg}" =~ "status=waiting-for" ]]; then
                state_blocking="blocked-by"
            # Dependency plugin is also blocked
            elif [[ "${blocker_msg}" =~ "status=blocked-by" ]]; then
                state_blocking="blocked-by"
            else
                state_blocking="waiting-for"
            fi

            # Reporting progress to sonobuoy progress API
            msg="status=${state_blocking}=${plugin_name}=(0/${remaining}/0)=[${timeout_checks}/${timeout_count}]"
            update_progress "dep-checker" "${msg}";

            # Timeout checker
            ## 1. Dont block by long running plugins (only non-updated)
            ## Timeout checks will increase only when previous jobs got stuck,
            ## otherwise it will be reset. It can avoid the plugin run infinitely,
            ## also avoid to set low timeouts for 'unknown' exec time on dependencies.
            if [[ ${count} -gt ${last_count} ]]; then
                last_count=${count}
                timeout_checks=0
                sleep 10
                continue
            fi
            # dont run timeouts for blockers plugins
            if [[ "${blocker_msg}" =~ "status=blocked-by" ]]; then
                timeout_checks=0
                sleep 10
                continue
            fi
            # dont run timeouts for if blocker is waiting
            if [[ "${blocker_msg}" =~ "status=waiting-for" ]] && [[ "${state_blocking}" =~ "blocked-by" ]]; then
                timeout_checks=0
                sleep 10
                continue
            fi
            last_count=${count}
            timeout_checks=$(( timeout_checks + 1 ))
            if [[ ${timeout_checks} -eq ${timeout_count} ]]; then
                echo "Timeout waiting condition 'complete' for plugin[${plugin_name}]."
                exit 1
            fi
            sleep 10
        done
        os_log_info_local "plugin [${plugin_name}] finished!"
    done
    os_log_info_local "[plugin dependencies] Finished!"
}

update_pogress_upgrade() {
    local progress_st
    local progress_message
    while true; do
        if [[ -f "${PLUGIN_DONE_NOTIFY}" ]]
        then
            echo "[report_progress] Done file detected"
            break
        fi
        progress_st=$(oc get -o jsonpath='{.status.conditions[?(@.type == "Progressing")].status}' clusterversion version)
        progress_message="upgrade-progressing-${progress_st}"
        if [[ "$progress_st" == "True" ]]; then
            progress_message=$(oc get -o jsonpath='{.status.conditions[?(@.type == "Progressing")].message}' clusterversion version)
        else
            desired_version=$(oc get -o jsonpath='{.status.desired.version}' clusterversion version)
            progress_message="${desired_version}=${progress_message}"
        fi
        update_progress "updater" "status=${progress_message}";
        sleep 10
    done
}

# report_progress reads the pipe file, parses the progress counters and reports it
# to worker progress endpoint until the piple file is closed and Done file is created
# by plugin container.
report_progress() {
    local has_update
    has_update=0
    while true
    do
        # Watch sonobuoy done file
        if [[ -f "${PLUGIN_DONE_NOTIFY}" ]]
        then
            echo "[report_progress] Done file detected"
            break
        fi

        while read -r line;
        do
            local job_progress
            job_progress=$(echo "$line" | grep -Po "\([0-9]{1,}\/[0-9]{1,}\/[0-9]{1,}\)" || true);
            if [[ -n "${job_progress}" ]]; then
                has_update=1;
                PROGRESS["completed"]=$(echo "${job_progress:1:-1}" | cut -d'/' -f 2)
                PROGRESS["total"]=$(echo "${job_progress:1:-1}" | cut -d'/' -f 3)

            elif [[ $line == failed:* ]]; then
                if [ -z "${PROGRESS["failures"]}" ]; then
                    PROGRESS["failures"]=\"$(echo "$line" | cut -d"\"" -f2)\"
                else
                    PROGRESS["failures"]+=,\"$(echo "$line" | cut -d"\"" -f2)\"
                fi
                has_update=1;
            fi

            if [[ $has_update -eq 1 ]] && [[ "${PLUGIN_ID}" != "2" ]]; then
                update_progress "updater" "status=running";
                has_update=0;
            fi
            job_progress="";

        done <"${RESULTS_PIPE}"
    done
}

#
# Main
#

openshift_login
init_config
wait_utils_extractor
update_config

PIDS_LOCAL=()
PROGRESS=( ["completed"]=0 ["total"]=${CERT_TEST_COUNT} ["failures"]="" ["msg"]="" )

wait_status_file

wait_progress_api
update_progress "init" "status=initializing";

wait_pipe_exists

watch_plugin_done &
PIDS_LOCAL+=($!)

watch_dependency_done &
PIDS_LOCAL+=($!)

# upgrade plugin
if [[ "${PLUGIN_ID}" == "2" ]]; then
    update_pogress_upgrade &
    PIDS_LOCAL+=($!)
fi

report_progress

os_log_info_local "Waiting for PIDs [finalizer]: ${PIDS_LOCAL[*]}"
wait "${PIDS_LOCAL[@]}"

update_progress "finalizer" "status=report-progress-finished";

os_log_info_local "all done"
