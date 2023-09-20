#!/usr/bin/env bash

declare -gx PLUGIN_NAME
declare -gx PLUGIN_BLOCKED_BY
declare -gx DEV_TESTS_COUNT

declare -grx CERT_TESTS_DIR="./tests/${OPENSHIFT_VERSION:-"v4.10"}"

declare -gx PLUGIN_ID
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

declare -gx MIRROR_IMAGE_REPOSITORY

# Utilities
declare -grx UTIL_OTESTS_BIN="${SHARED_DIR}/openshift-tests"
declare -grx UTIL_OTESTS_READY="${UTIL_OTESTS_BIN}.ready"
declare -grx UTIL_OTESTS_FAILED="${UTIL_OTESTS_BIN}.failed"

declare -grx UTIL_OC_BIN="/usr/bin/oc"
declare -grx UTIL_OC_READY="${SHARED_DIR}/oc.ready"
declare -grx UTIL_OC_FAILED="${SHARED_DIR}/oc.failed"

declare -grx CHECK_MCP_READY="${SHARED_DIR}/upgrade-mcp.ready"
declare -grx CHECK_MCP_FAILED="${SHARED_DIR}/upgrade-mcp.failed"

# PLUGIN Instances vars
## openshift-cluster-upgrade
declare -grx PLUGIN_ID_OPENSHIFT_UPGRADE="05"
declare -grx PLUGIN_NAME_OPENSHIFT_UPGRADE="${PLUGIN_ID_OPENSHIFT_UPGRADE}-openshift-cluster-upgrade"
declare -grx OPENSHIFT_TESTS_SUITE_UPGRADE="none"

## openshift-kube-conformance
declare -grx PLUGIN_ID_KUBE_CONFORMANCE="10"
declare -grx PLUGIN_NAME_KUBE_CONFORMANCE="${PLUGIN_ID_KUBE_CONFORMANCE}-openshift-kube-conformance"
declare -grx OPENSHIFT_TESTS_SUITE_KUBE_CONFORMANCE="${PLUGIN_SUITE_KUBE_CONFORMANCE:-kubernetes/conformance}"

## openshift-conformance-validated
declare -grx PLUGIN_ID_OPENSHIFT_CONFORMANCE="20"
declare -grx PLUGIN_NAME_OPENSHIFT_CONFORMANCE="${PLUGIN_ID_OPENSHIFT_CONFORMANCE}-openshift-conformance-validated"
declare -grx OPENSHIFT_TESTS_SUITE_OPENSHIFT_CONFORMANCE="${PLUGIN_SUITE_OPENSHIFT_CONFORMANCE:-openshift/conformance}"

## openshift-artifacts-collector
declare -grx PLUGIN_ID_OPENSHIFT_ARTIFACTS_COLLECTOR="99"
declare -grx PLUGIN_NAME_OPENSHIFT_ARTIFACTS_COLLECTOR="${PLUGIN_ID_OPENSHIFT_ARTIFACTS_COLLECTOR}-openshift-artifacts-collector"

# Plugin Execution modes (| regular | upgrade). Default: regular|''
declare -grx PLUGIN_RUN_MODE_UPGRADE="upgrade"

# Sonobuot Plugin Statuses
declare -grx SONOBUOY_PLUGIN_STATUS_COMPLETE="complete"
declare -grx SONOBUOY_PLUGIN_STATUS_FAILED="failed"

## Setting 3h for the plugin blocker feature (wait-plugin).
## We don't want to run forever, however starting prematurely is not acceptable.
declare -grx PLUGIN_WAIT_TIMEOUT_COUNT=1080
declare -grx PLUGIN_WAIT_TIMEOUT_INTERVAL=10

# Defaults
CERT_TEST_FILE=""
CERT_TEST_SUITE=""
CERT_TEST_COUNT=0
CERT_TEST_PARALLEL=${E2E_PARALLEL:-${E2E_PARALLEL_DEFAULT}}
DEV_TESTS_COUNT="${DEV_MODE_COUNT:-0}"
