#!/usr/bin/env bash

declare -gx PLUGIN_NAME
declare -gx PLUGIN_BLOCKED_BY
declare -gx PLUGIN_ID
declare -gx PLUGIN_RESULT_FORMAT
declare -gx DEV_TESTS_COUNT
declare -gx RUN_MODE

declare -gx CERT_TEST_FILE
declare -gx CERT_TEST_COUNT
declare -gx CERT_TEST_SUITE
declare -gx CERT_TEST_PARALLEL

declare -gAx PROGRESS
declare -grx PROGRESS_URL="http://127.0.0.1:8099/progress"
declare -grx SHARED_DIR="/tmp/shared"
declare -grx SONOBUOY_BIN="/usr/bin/sonobuoy"
declare -grx STATUS_FILE="${SHARED_DIR}/sonobuoy-status.json"
declare -grx STATUS_UPDATE_INTERVAL_SEC="5"
declare -grx E2E_PARALLEL_DEFAULT=0

declare -grx RESULTS_DIR="${RESULTS_DIR:-/tmp/sonobuoy/results}"
declare -grx RESULTS_DONE_NOTIFY="${RESULTS_DIR}/done"
declare -grx PLUGIN_DONE_NOTIFY="${SHARED_DIR}/plugin.done"
declare -grx RESULTS_PIPE="${SHARED_DIR}/status_pipe"
declare -grx RESULTS_SCRIPTS="${SHARED_DIR}/plugin-scripts"

declare -grx KUBECONFIG="${SHARED_DIR}/kubeconfig"
declare -grx KUBE_API_INT="https://172.30.0.1:443"
declare -grx SA_CA_PATH="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
declare -grx SA_TOKEN_PATH="/var/run/secrets/kubernetes.io/serviceaccount/token"

declare -grx UTIL_OTESTS_BIN="${SHARED_DIR}/openshift-tests"
declare -grx UTIL_OTESTS_READY="${SHARED_DIR}/openshift-tests.ready"
declare -grx UTIL_OTESTS_FAILED="${SHARED_DIR}/openshift-tests.failed"

# PLUGIN Instances
declare -grx PLUGIN_ID_KUBE_CONFORMANCE="10"
declare -grx PLUGIN_NAME_KUBE_CONFORMANCE="${PLUGIN_ID_KUBE_CONFORMANCE}-openshift-kube-conformance"
declare -grx OPENSHIFT_TESTS_SUITE_KUBE_CONFORMANCE="kubernetes/conformance"

declare -grx PLUGIN_ID_OPENSHIFT_CONFORMANCE="20"
declare -grx PLUGIN_NAME_OPENSHIFT_CONFORMANCE="${PLUGIN_ID_OPENSHIFT_CONFORMANCE}-openshift-conformance-validated"
declare -grx OPENSHIFT_TESTS_SUITE_OPENSHIFT_CONFORMANCE="openshift/conformance"

declare -grx PLUGIN_ID_OPENSHIFT_UPGRADE="05"
declare -grx PLUGIN_NAME_OPENSHIFT_UPGRADE="${PLUGIN_ID_OPENSHIFT_UPGRADE}-openshift-cluster-upgrade"

declare -grx PLUGIN_ID_OPENSHIFT_ARTIFACTS="99"
declare -grx PLUGIN_NAME_OPENSHIFT_ARTIFACTS="${PLUGIN_ID_OPENSHIFT_ARTIFACTS}-openshift-artifacts-collector"

# declare -grx PLUGIN_ID_OPENSHIFT_UPGRADE="05"
declare -grx PLUGIN_RUN_MODE_UPGRADE="upgrade"

declare -grx SONOBUOY_PLUGIN_STATUS_COMPLETE="complete"
declare -grx SONOBUOY_PLUGIN_STATUS_FAILED="failed"
declare -grx SONOBUOY_PLUGIN_STATUS_RUNNING="running"

declare -grx RESULT_RAW_FILE_NAME="raw-results.tar.gz"
declare -grx RESULT_RAW_FILE_PATH="${RESULTS_DIR}/${RESULT_RAW_FILE_NAME}"

# Defaults
RUN_MODE="regular"
CERT_TEST_FILE=""
CERT_TEST_SUITE=""
CERT_TEST_COUNT=0
CERT_TEST_PARALLEL=${E2E_PARALLEL:-${E2E_PARALLEL_DEFAULT}}
DEV_TESTS_COUNT="${DEV_MODE_COUNT:-0}"
