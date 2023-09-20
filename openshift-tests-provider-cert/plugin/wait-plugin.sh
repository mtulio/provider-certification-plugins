#!/usr/bin/env bash

#set -x
set -o pipefail
set -o nounset
# set -o errexit

os_log_info_local() {
    os_log_info "[waiter] $*"
}

os_log_info_local "Starting Level[${PLUGIN_ID:-}]..."
init_config

os_log_info_local "Checking if there's plugins blocking Level${PLUGIN_ID:-} execution..."
if [[ ${#PLUGIN_BLOCKED_BY[@]} -ge 1 ]]; then
    os_log_info_local "Level${PLUGIN_ID:-} plugin is blocked by: [${PLUGIN_BLOCKED_BY[*]}]"
    for pod_label in "${PLUGIN_BLOCKED_BY[@]}"; do
        os_log_info_local "Waiting for pod running with label: ${pod_label}"
        kubectl wait \
            --namespace "${ENV_POD_NAMESPACE:-sonobuoy}" \
            --timeout=3m \
            --for=condition=ready pod \
            --field-selector=status.phase!=Succeeded \
            -l sonobuoy-plugin="${pod_label}"
    done

    os_log_info_local "Resource(s) ready! Waiting for Level[${PLUGIN_ID:-}]'s plugins be completed..."
    for bl_plugin_name in "${PLUGIN_BLOCKED_BY[@]}"; do
        os_log_info_local "Waiting 'completed' condition for pod: ${bl_plugin_name}"
        
        # Wait until sonobuoy job is completed
        timeout_checks=0
        timeout_count=${PLUGIN_WAIT_TIMEOUT_COUNT}
        last_count=0
        while true;
        do
            # TODO(bug:st-updater): avoid check status in empty file
            if [[ ! -s "${STATUS_FILE}" ]]; then
                os_log_info_local "Plugin[${bl_plugin_name}] status WARNING: empty status detected...waiting next check..."
                sleep "${PLUGIN_WAIT_TIMEOUT_INTERVAL}"
                continue
            fi
            plugin_status=$(jq -r ".plugins[] | select (.plugin == \"${bl_plugin_name}\" ) |.status // \"\"" "${STATUS_FILE}")

            os_log_info_local "Plugin[${bl_plugin_name}] with status[${plugin_status}]..."
            #os_log_info_local "$(cat "${STATUS_FILE}")"
            if [[ "${plugin_status}" == "${SONOBUOY_PLUGIN_STATUS_COMPLETE}" ]] || [[ "${plugin_status}" == "${SONOBUOY_PLUGIN_STATUS_FAILED}" ]]; then
                os_log_info_local "Plugin[${bl_plugin_name}] with status[${plugin_status}] is completed!"
                break
            fi

            # Timeout checker
            ## 1. Dont block by long running plugins (only non-updated)
            ## Timeout checks will increase only when previous jobs got stuck,
            ## otherwise it will be reset. It can avoid the plugin run infinitely,
            ## also avoid to set low timeouts for 'unknown' exec time on dependencies.
            count=$(jq -r ".plugins[] | select (.plugin == \"${bl_plugin_name}\" ) |.progress.completed // 0" "${STATUS_FILE}")
            if [[ ${count} -gt ${last_count} ]]; then
                last_count=${count}
                timeout_checks=0
                sleep "${PLUGIN_WAIT_TIMEOUT_INTERVAL}"
                continue
            fi
            ## 2. Dont get stuck for blocked plugins (which is already waiting for deps)
            blocker_msg=$(jq -r ".plugins[] | select (.plugin == \"${bl_plugin_name}\" ) |.progress.msg // \"\"" "${STATUS_FILE}")
            current_msg=$(jq -r ".plugins[] | select (.plugin == \"${PLUGIN_NAME}\" ) |.progress.msg // \"\"" "${STATUS_FILE}")
            if [[ "${blocker_msg}" =~ "status=blocked-by" ]]; then
                timeout_checks=0
                sleep "${PLUGIN_WAIT_TIMEOUT_INTERVAL}"
                continue
            ## Should wait for blocker timeout (then !waiting-for state) to start timeout count
            elif [[ "${blocker_msg}" =~ "status=waiting-for" ]] && [[ "${current_msg}" =~ "status=blocked-by" ]]; then
                timeout_checks=0
                sleep "${PLUGIN_WAIT_TIMEOUT_INTERVAL}"
                continue
            fi
            last_count=${count}
            timeout_checks=$(( timeout_checks + 1 ))
            if [[ ${timeout_checks} -eq ${timeout_count} ]]; then
                os_log_info_local "Timeout waiting condition 'complete' for plugin[${bl_plugin_name}]."
                exit 1
            fi
            os_log_info_local "Waiting 30s for Plugin[${bl_plugin_name}]...[${timeout_checks}/${timeout_count}]"
            sleep "${PLUGIN_WAIT_TIMEOUT_INTERVAL}"
        done
    done
    os_log_info_local "All the conditions has been met!"
fi

os_log_info_local "Done for Level[${PLUGIN_ID:-}]."
