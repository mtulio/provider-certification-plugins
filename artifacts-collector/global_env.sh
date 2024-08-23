#!/usr/bin/env bash

declare -gx PLUGIN_NAME
declare -gx PLUGIN_BLOCKED_BY
declare -gx DEV_TESTS_COUNT

declare -grx IMAGE_OVERRIDE_MUST_GATHER="${IMAGE_OVERRIDE_MUST_GATHER:-"quay.io/opct/must-gather-monitoring:v0.5.0"}"
declare -grx VERSION_IMAGE_MUST_GATHER="${VERSION_IMAGE_MUST_GATHER:-"v0.5.0"}"

declare -gx PLUGIN_ID
declare -gx CERT_TEST_COUNT
CERT_TEST_COUNT=0

declare -gAx PROGRESS
declare -grx SHARED_DIR="/tmp/shared"

declare -grx RESULTS_DIR="${RESULTS_DIR:-/tmp/sonobuoy/results}"
declare -grx RESULTS_DONE_NOTIFY="${RESULTS_DIR}/done"
declare -grx PLUGIN_DONE_NOTIFY="${SHARED_DIR}/plugin.done"

declare -grx KUBECONFIG="${SHARED_DIR}/kubeconfig"
declare -grx KUBE_API_INT="https://kubernetes.default.svc:443"
declare -grx SA_CA_PATH="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
declare -grx SA_TOKEN_PATH="/var/run/secrets/kubernetes.io/serviceaccount/token"

declare -gx MIRROR_IMAGE_REPOSITORY

# Utilities
declare -grx UTIL_OC_BIN="/usr/bin/oc"

# Kube Burner
KUBE_BURNER_DEFAULT_COMMANDS="node-density node-density-cni cluster-density-v2"
declare -gx KUBE_BURNER_COMMANDS="${KUBE_BURNER_COMMANDS:-${KUBE_BURNER_DEFAULT_COMMANDS}}"
