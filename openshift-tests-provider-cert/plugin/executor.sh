#!/usr/bin/env bash

#
# openshift-tests-partner-cert runner
#

#TODO: pipefail should be disabled until a better solution is provided
# to handle errors (failed e2e) on sub-process managed by openshift-tests binary.
# https://issues.redhat.com/browse/SPLAT-592
#set -o pipefail
#set -o errexit
set -o nounset

os_log_info "[executor] Starting..."

IMAGE_MIRROR=""
if [ -n "${MIRROR_IMAGE_REPOSITORY:-}" ]; then
    IMAGE_MIRROR="--from-repository ${MIRROR_IMAGE_REPOSITORY}"
    os_log_info "[executor] Disconnected image registry configured"
fi

os_log_info "[executor] Checking if credentials are present..."
test -f "${SA_CA_PATH}" || os_log_info "[executor] secret not found=${SA_CA_PATH}"
test -f "${SA_TOKEN_PATH}" || os_log_info "[executor] secret not found=${SA_TOKEN_PATH}"

#
# Upgrade functions
#

# Run the upgrade with openshift-tests
run_upgrade() {
    set -x &&
    os_log_info "[executor] [upgrade] UPGRADE_RELEASES=${UPGRADE_RELEASES}"
    os_log_info "[executor] [upgrade] show current version:"
    ${UTIL_OC_BIN} get clusterversion
    # shellcheck disable=SC2086
    ${UTIL_OTESTS_BIN} run-upgrade "${OPENSHIFT_TESTS_SUITE_UPGRADE}" ${IMAGE_MIRROR} \
        --to-image "${UPGRADE_RELEASES}" \
        --options "${TEST_UPGRADE_OPTIONS-}" \
        --junit-dir "${RESULTS_DIR}" \
        | tee -a "${RESULTS_PIPE}"
    set +x
}

# Run Plugin for Cluster Upgrade using openshift-tests binary when the plugin
# instance is the upgrade running in mode=upgrade (CLI option). When success
# the results will be saved in JUnit format, otherwise the custom failures will
# be created.
run_plugin_upgrade() {
    # the plugin instance 'upgrade' will always run, depending of the CLI setting
    # RUN_MODE, the upgrade will be started or not
    os_log_info "[executor] PLUGIN=${PLUGIN_ID} on mode=${RUN_MODE:-''}"
    if [[ "${RUN_MODE:-''}" == "${PLUGIN_RUN_MODE_UPGRADE}" ]]; then
        PROGRESSING="$(oc get -o jsonpath='{.status.conditions[?(@.type == "Progressing")].status}' clusterversion version)"
        os_log_info "[executor] Running Plugin_ID ${PLUGIN_ID}, starting... Cluster is progressing? ${PROGRESSING}"

        run_upgrade

        PROGRESSING="$(oc get -o jsonpath='{.status.conditions[?(@.type == "Progressing")].status}' clusterversion version)"
        os_log_info "[executor] Running Plugin_ID ${PLUGIN_ID}. finished... Cluster is progressing? ${PROGRESSING}"

    else
        os_log_info "[executor] Creating pass JUnit files due the execution mode != upgrade"
        create_junit_with_msg "pass" "[opct][pass] ignoring upgrade mode on RUN_MODE=[${RUN_MODE-}]." "upgrade"
    fi
}

#
# Conformance functions
#

# Run Conformance Plugins calling openshift-tests, when success the JUnit will be
# created, otherwise custom error is raised as custom result file (JUnits).
run_plugins_conformance() {

    if [[ -z "${CERT_TEST_SUITE}" ]]; then
        err="[executor][PluginID#${PLUGIN_ID}] CERT_TEST_SUITE should be always defined. Current value: ${CERT_TEST_SUITE}"
        os_log_info "${err}"
        create_junit_with_msg "failed" "[opct] ${err}"
        exit 1
    fi

    os_log_info "[executor][PluginID#${PLUGIN_ID}] Starting openshift-tests suite [${CERT_TEST_SUITE}] Provider Conformance executor..."

    set -x
    ${UTIL_OTESTS_BIN} run \
        "${CERT_TEST_SUITE}" --dry-run \
        > "${RESULTS_DIR}/suite-${CERT_TEST_SUITE/\/}.list"

    os_log_info "Saving the test list on ${RESULTS_DIR}/suite-${CERT_TEST_SUITE/\/}.list"
    wc -l "${RESULTS_DIR}/suite-${CERT_TEST_SUITE/\/}.list"

    # "Dev Mode": limit the number of tests to run in development with CLI run option (--dev-count N)
    if [[ ${DEV_TESTS_COUNT} -gt 0 ]]; then
        os_log_info "DEV mode detected, applying filter to job count: [${DEV_TESTS_COUNT}]"
        shuf "${RESULTS_DIR}/suite-${CERT_TEST_SUITE/\/}.list" \
            | head -n "${DEV_TESTS_COUNT}" \
            > "${RESULTS_DIR}/suite-${CERT_TEST_SUITE/\/}-DEV.list"

        os_log_info "Saving the DEV test list on ${RESULTS_DIR}/suite-${CERT_TEST_SUITE/\/}-DEV.list"
        wc -l "${RESULTS_DIR}/suite-${CERT_TEST_SUITE/\/}-DEV.list"

        os_log_info "Running on DEV mode..."
        # shellcheck disable=SC2086
        ${UTIL_OTESTS_BIN} run \
            --max-parallel-tests "${CERT_TEST_PARALLEL}" ${IMAGE_MIRROR} \
            --junit-dir "${RESULTS_DIR}" \
            -f "${RESULTS_DIR}/suite-${CERT_TEST_SUITE/\/}-DEV.list" \
            | tee -a "${RESULTS_PIPE}" || true

        os_log_info "[executor][PluginID#${PLUGIN_ID}] openshift-tests finished[$?] (DEV Mode)"
        return
    fi

    # Regular Conformance runner
    os_log_info "Running the test suite..."
    # shellcheck disable=SC2086
    ${UTIL_OTESTS_BIN} run \
        --max-parallel-tests "${CERT_TEST_PARALLEL}" ${IMAGE_MIRROR} \
        --junit-dir "${RESULTS_DIR}" \
        "${CERT_TEST_SUITE}" \
        | tee -a "${RESULTS_PIPE}" || true

    os_log_info "[executor][PluginID#${PLUGIN_ID}] openshift-tests finished[$?]"
    set +x
}

#
# Collector functions
#

# Collect must-gather and pre-process any data* from it, then create a tarball file.
collect_must_gather() {
    os_log_info "[executor][PluginID#${PLUGIN_ID}] Collecting must-gather"
    ${UTIL_OC_BIN} adm must-gather --dest-dir=must-gather-opct

    # TODO: Pre-process data from must-gather to avoid client-side extra steps.
    # Examples of data to be processed:
    # > insights rules

    # extracting msg from etcd logs: request latency apply took too long (attl)
    os_log_info "[executor][PluginID#${PLUGIN_ID}] Collecting etcd log filters"
    cat must-gather-opct/*/namespaces/openshift-etcd/pods/*/etcd/etcd/logs/current.log \
        | ocp-etcd-log-filters \
        > artifacts_must-gather_parser-etcd-attl-all.txt
    cat must-gather-opct/*/namespaces/openshift-etcd/pods/*/etcd/etcd/logs/current.log \
        | ocp-etcd-log-filters -aggregator hour \
        > artifacts_must-gather_parser-etcd-attl-hour.txt

    # generate camgi report
    os_log_info "[executor][PluginID#${PLUGIN_ID}] Generating camgi report"
    camgi must-gather-opct/ > artifacts_must-gather_camgi.html || true

    # Create the tarball file artifacts_must-gather.tar.xz
    os_log_info "[executor][PluginID#${PLUGIN_ID}] Packing must-gather"
    tar cfJ artifacts_must-gather.tar.xz must-gather-opct*

    os_log_info "[executor][PluginID#${PLUGIN_ID}] must-gather collector done."
}

# Collect e2e Conformance tests from a given suite, it will save the list into a file.
collect_tests_conformance() {
    local suite
    local ofile
    suite=$1; shift
    ofile=$1; shift
    os_log_info "[executor][PluginID#${PLUGIN_ID}] Collecting e2e list> ${suite}"

    truncate -s 0 "${ofile}"
    CNT_T=$(${UTIL_OTESTS_BIN} run "${suite}" --dry-run -o "${ofile}" | wc -l)
    CNT_C=$(wc -l "${ofile}" | awk '{print$1}')

    os_log_info "[executor][PluginID#${PLUGIN_ID}] e2e count ${suite} openshift-tests> ${CNT_T}"
    os_log_info "[executor][PluginID#${PLUGIN_ID}] e2e count ${suite} collected> ${CNT_C}"
}

collect_tests_upgrade() {
    suite="${OPENSHIFT_TESTS_SUITE_UPGRADE}"
    ofile="./artifacts_e2e-tests_openshift-upgrade.txt"
    truncate -s 0 ${ofile}
    if [[ "${RUN_MODE:-''}" == "${PLUGIN_RUN_MODE_UPGRADE}" ]]; then
        ${UTIL_OTESTS_BIN} run-upgrade "${suite}" --to-image "${UPGRADE_RELEASES:-}" --dry-run || true > ${ofile}
        CNT_T=$(${UTIL_OTESTS_BIN} run-upgrade "${suite}" --to-image "${UPGRADE_RELEASES:-}" --dry-run || true | wc -l)
        os_log_info "[executor][PluginID#${PLUGIN_ID}] e2e count ${suite} openshift-tests> ${CNT_T}"
    fi
    CNT_C=$(wc -l ${ofile} | awk '{print$1}')
    os_log_info "[executor][PluginID#${PLUGIN_ID}] e2e count ${suite} collected> ${CNT_C}"
}

# WIP: require a server to setup
# 
collect_performance_iperf() {
    idx=0
    node_role="master"
    for node in $(oc get nodes -l kubernetes.io/node-role=master -o jsonpath='{.items[*].metadata.name}'); do
        oc debug node/$node -- chroot /host /bin/bash -c "podman run -ti --rm --net host quay.io/kinvolk/iperf3 iperf3 -s"\
            > ./artifacts_performance_iperf3_$node_role-$node-$idx.txt
        idx=$((idx+1))
        test idx -eq 2 && continue
    done
}

collect_performance_etcdfio() {

    os_log_info "[executor][PluginID#${PLUGIN_ID}] Starting Artifacts Collector - Performance - etcdfio"

    os_log_info "[executor][PluginID#${PLUGIN_ID}][performance][etcdfio] master"
    local idx=0
    node_role="controlplane"
    for node in $(${UTIL_OC_BIN} get nodes -l 'node-role.kubernetes.io/master' -o jsonpath='{.items[*].metadata.name}'); do
        os_log_info "[executor][PluginID#${PLUGIN_ID}][performance][etcdfio] ${node_role}#${idx}: ${node}"
        result_file="./artifacts_performance_etcdfio_${node_role}-${idx}.txt"
        oc debug node/"${node}" -- chroot /host /bin/bash -c "podman run --volume /var/lib/etcd:/var/lib/etcd:Z quay.io/openshift-scale/etcd-perf" > "${result_file}";
        echo "etcdfio=${node}=$(grep ^'INFO: 99th percentile of fsync is ' ${result_file} | awk -F'of fsync is ' '{print$2}')" >> ${result_file}
        idx=$((idx+1))
        test $idx -ge 3 && break
    done

    os_log_info "[executor][PluginID#${PLUGIN_ID}][performance][etcdfio] worker"
    idx=0
    node_role="worker"
    for node in $(${UTIL_OC_BIN} get nodes -l '!node-role.kubernetes.io/master' -o jsonpath='{.items[*].metadata.name}'); do
        os_log_info "[executor][PluginID#${PLUGIN_ID}][performance][etcdfio] ${node_role}#${idx}: ${node}"
        result_file="./artifacts_performance_etcdfio_${node_role}-${idx}.txt"
        oc debug node/"${node}" -- chroot /host /bin/bash -c "mkdir /var/cache/opct; podman run --volume /var/cache/opct:/var/lib/etcd:Z quay.io/openshift-scale/etcd-perf" > "${result_file}";
        echo "etcdfio=${node}=$(grep ^'INFO: 99th percentile of fsync is ' ${result_file} | awk -F'of fsync is ' '{print$2}')" >>  ${result_file}
        idx=$((idx+1))
        test $idx -ge 2 && break
    done
}

# collect performance tests
collect_performance() {

    collect_performance_etcdfio

    # TODO
    #collect_performance_iperf
}

# collect_metrics extracts metrics from Prometheus within the time frame the
# OPCT was executed (~6 hours), saving it as a raw data into the
# artifact path. The Prometheus expression are preferred than the raw metric to
# save storage and server-side CPU/RAM processing raw data.
# The expressions are extracted from OpenShift Dashboards.
# There is no automation to load the extracted data at this moment. There were
# some initial work backfilling raw prometheus query in this project:
# https://github.com/mtulio/must-gather-monitoring#load-metrics-to-a-local-prometheus-deployment
# The collector script (must-gather-monitoring) was adapted from the original proposal:
# https://github.com/openshift/must-gather/pull/214
collect_metrics() {
    os_log_info "[executor][PluginID#${PLUGIN_ID}] Starting Metrics Collector"
    # Create a ConfigMap to store variables
    cat << EOF > ./collect-metrics.env
GATHER_MONIT_START_DATE='6 hours ago'
GATHER_MONIT_QUERY_STEP='1m'

# Dashboard (4.14): API Performance apiserver[kube-apiserver] period=[5m]:
# API Request Duration by Verb - 99th Percentile [api-kas-request-duration-p99]
declare -A OPT_GATHER_QUERY_RANGE=( [api-kas-request-duration-p99]='histogram_quantile(0.99, sum(resource_verb:apiserver_request_duration_seconds_bucket:rate:5m{apiserver="kube-apiserver"}) by (verb, le))' )
OPT_GATHER_QUERY_RANGE+=( [etcd-request-duration-p99]='histogram_quantile(0.99, operation:etcd_request_duration_seconds_bucket:rate5m)' )

# Dashboard (4.14): etcd cluster=[etcd]:
OPT_GATHER_QUERY_RANGE+=( [etcd-disk-fsync-db-duration-p99]='histogram_quantile(0.99, sum(rate(etcd_disk_backend_commit_duration_seconds_bucket{job="etcd"}[5m])) by (instance, le))' )
OPT_GATHER_QUERY_RANGE+=( [etcd-disk-fsync-wal-duration-p99]='histogram_quantile(0.99, sum(rate(etcd_disk_wal_fsync_duration_seconds_bucket{job="etcd"}[5m])) by (instance, le))' )
OPT_GATHER_QUERY_RANGE+=( [etcd-total-leader-elections-day]='changes(etcd_server_leader_changes_seen_total{job="etcd"}[1d])' )
OPT_GATHER_QUERY_RANGE+=( [etcd-peer-round-trip-time]='histogram_quantile(0.99, sum by (instance, le) (rate(etcd_network_peer_round_trip_time_seconds_bucket{job="etcd"}[5m])))' )
OPT_GATHER_QUERY_RANGE+=( [etcd-disk-fsync-wal-duration-p10]='histogram_quantile(0.1, sum by(instance, le) (irate(etcd_disk_wal_fsync_duration_seconds_bucket{job="etcd"}[5m])))' )
OPT_GATHER_QUERY_RANGE+=( [etcd-disk-fsync-wal-duration-p50]='histogram_quantile(0.5, sum by(instance, le) (irate(etcd_disk_wal_fsync_duration_seconds_bucket{job="etcd"}[5m])))' )
OPT_GATHER_QUERY_RANGE+=( [etcd-disk-fsync-wal-duration-p80]='histogram_quantile(0.8, sum by(instance, le) (irate(etcd_disk_wal_fsync_duration_seconds_bucket{job="etcd"}[5m])))' )

# Dashboard (4.14): Kubernetes / Compute Resources / Cluster (by namespace)
OPT_GATHER_QUERY_RANGE+=( [cluster-cpu-usage]='sum(node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate{cluster=""}) by (namespace)' )
OPT_GATHER_QUERY_RANGE+=( [cluster-memory-usage-wo-cache]='sum(container_memory_rss{job="kubelet", metrics_path="/metrics/cadvisor", cluster="", container!=""}) by (namespace)' )
OPT_GATHER_QUERY_RANGE+=( [cluster-storage-iops]='ceil(sum by(namespace) (rate(container_fs_reads_total{job="kubelet", metrics_path="/metrics/cadvisor", id!="", device=~"(/dev.+)|mmcblk.p.+|nvme.+|rbd.+|sd.+|vd.+|xvd.+|dm-.+|dasd.+", cluster="", namespace!=""}[5m]) + rate(container_fs_writes_total{job="kubelet", metrics_path="/metrics/cadvisor", id!="", cluster="", namespace!=""}[5m])))' )
OPT_GATHER_QUERY_RANGE+=( [cluster-storage-throughput]='sum by(namespace) (rate(container_fs_reads_bytes_total{job="kubelet", metrics_path="/metrics/cadvisor", id!="", device=~"(/dev.+)|mmcblk.p.+|nvme.+|rbd.+|sd.+|vd.+|xvd.+|dm-.+|dasd.+", cluster="", namespace!=""}[5m]) + rate(container_fs_writes_bytes_total{job="kubelet", metrics_path="/metrics/cadvisor", id!="", cluster="", namespace!=""}[5m]))' )

# Dashboard (4.14): Node Exporter  USE Method / Node
OPT_GATHER_QUERY_RANGE+=( [node-cpu-saturation-load1]='(instance:node_load1_per_cpu:ratio{job="node-exporter", cluster=""} / scalar(count(instance:node_load1_per_cpu:ratio{job="node-exporter", cluster=""})))  != 0' )
OPT_GATHER_QUERY_RANGE+=( [node-memory-saturation]='instance:node_vmstat_pgmajfault:rate1m{job="node-exporter", cluster=""}' )
OPT_GATHER_QUERY_RANGE+=( [node-network-saturation-tx]='instance:node_network_transmit_drop_excluding_lo:rate1m{job="node-exporter", cluster=""} != 0' )
OPT_GATHER_QUERY_RANGE+=( [node-network-saturation-rx]='instance:node_network_receive_drop_excluding_lo:rate1m{job="node-exporter", cluster=""} != 0' )
OPT_GATHER_QUERY_RANGE+=( [node-disk-saturation]='( instance_device:node_disk_io_time_weighted_seconds:rate1m{job="node-exporter", cluster=""} / scalar(count(instance_device:node_disk_io_time_weighted_seconds:rate1m{job="node-exporter", cluster=""}))) != 0' )
EOF

    os_log_info "[executor][PluginID#${PLUGIN_ID}][metrics] Creating config env file"
    ${UTIL_OC_BIN} delete configmap must-gather-metrics -n "$ENV_POD_NAMESPACE" || true
    mg_image=quay.io/opct/must-gather-monitoring:2a9f0fc-20230919233734
    ${UTIL_OC_BIN} create configmap must-gather-metrics -n "$ENV_POD_NAMESPACE" --from-file=env=collect-metrics.env &&\
        ${UTIL_OC_BIN} adm must-gather --dest-dir=must-gather-metrics --image=$mg_image \
        -- /usr/bin/gather --use-cm "$ENV_POD_NAMESPACE"/must-gather-metrics

    # Create the tarball file removing the image name from the path of must-gather
    os_log_info "[executor][PluginID#${PLUGIN_ID}] Packing must-gather-metrics"
    cp -v must-gather-metrics/timestamp must-gather-metrics/event-filter.html must-gather-metrics/*/monitoring/
    tar cfJ artifacts_must-gather-metrics.tar.xz -C must-gather-metrics/*/ monitoring/
}

# Run Plugin for Collecor. The Collector plugin is the last one executed on the
# cluster. It will collect custom files used on the Validation environment, at the
# end it will generate a tarbal file to submit the raw results to Sonobuoy.
run_plugin_collector() {
    os_log_info "[executor][PluginID#${PLUGIN_ID}] Starting Artifacts Collector"

    pushd "${RESULTS_DIR}" || true

    # Collecting must-gather
    collect_must_gather

    # Experimental: Collect performance data
    # running after must-gather to prevent impacting in etcd logs when testing etcdfio.
    collect_performance

    # Experimental: Collect metrics
    collect_metrics

    # Collecting e2e list for Kubernetes Conformance
    collect_tests_conformance "${OPENSHIFT_TESTS_SUITE_KUBE_CONFORMANCE}" "./artifacts_e2e-tests_kubernetes-conformance.txt"

    # Collecting e2e list for OpenShift Conformance
    collect_tests_conformance "${OPENSHIFT_TESTS_SUITE_OPENSHIFT_CONFORMANCE}" "./artifacts_e2e-tests_openshift-conformance.txt"

    # Collecting e2e list for OpenShift Upgrade (when mode=upgrade)
    collect_tests_upgrade

    # Creating Result file used to publish to sonobuoy. (last step)
    os_log_info "[executor][PluginID#${PLUGIN_ID}] Packing all results..."
    ls -sh ./artifacts_*
    tar cfz raw-results.tar.gz ./artifacts_*

    popd || true;
}

#
# Executor options
#
os_log_info "[executor] Executor started. Choosing execution type based on environment sets."


case "${PLUGIN_ID}" in
    "${PLUGIN_ID_OPENSHIFT_UPGRADE}") run_plugin_upgrade ;;
    "${PLUGIN_ID_KUBE_CONFORMANCE}"|"${PLUGIN_ID_OPENSHIFT_CONFORMANCE}") run_plugins_conformance ;;
    "${PLUGIN_ID_OPENSHIFT_ARTIFACTS_COLLECTOR}") run_plugin_collector ;;
    *) os_log_info "[executor] PluginID." ;;
esac

os_log_info "Plugin executor finished. Result[$?]";
