# must-gather-monitoring

The must-gather-monitoring collects metrics from monitoring
stack (Prometheus) on OpenShift/OKD.

The must-gather-monitoring container image is available in
the repository `quay.io/opct/must-gather-monitoring`.

OPCT runs the must-gather-monitoring in the collector plugin `99-openshift-artifacts-collector` (instance of `openshift-tests-provider-cert`).

You can find the tarball file with the metrics collected by OPCT plugin in the following path of OPCT result tarball:
`plugins/99-openshift-artifacts-collector/results/global/artifacts_must-gather-metrics.tar.xz`.

## Explore the metrics collected by OPCT

1. Retrieve OPCT results

```bash
./opct retrieve
```

1. Extract the metrics from archive

```bash
mkdir metrics;
tar xfz opct_archive.tar.gz plugins/99-openshift-artifacts-collector/results/global/artifacts_must-gather-metrics.tar.xz -C metrics 
```

1. Explore the metrics, each query are saved into a file:

```bash
$ ls metrics/monitoring/prometheus/metrics/
query_range-api-kas-request-duration-p99.json.gz     query_range-etcd-disk-fsync-wal-duration-p10.json.gz  query_range-etcd-total-leader-elections-day.json.gz
query_range-api-kas-request-duration-p99.stderr      query_range-etcd-disk-fsync-wal-duration-p10.stderr   query_range-etcd-total-leader-elections-day.stderr

```

1. Explore the metrics data points

```bash
jq . $(zcat metrics/monitoring/prometheus/metrics/query_range-api-kas-request-duration-p99.json.gz)
```

## Run the standalone collector

1. Create the config map with queries to collect:

```bash
cat << EOF > ./collect-metrics.env
GATHER_MONIT_START_DATE='6 hours ago'
GATHER_MONIT_QUERY_STEP='1m'
# API Request Duration by Verb - 99th Percentile [api-kas-request-duration-p99]
declare -A OPT_GATHER_QUERY_RANGE=( [api-kas-request-duration-p99]='histogram_quantile(0.99, sum(resource_verb:apiserver_request_duration_seconds_bucket:rate:5m{apiserver="kube-apiserver"}) by (verb, le))' )
EOF
```

2. Collect the metrics running must-gather

```bash
oc adm must-gather --image=quay.io/opct/must-gather-monitoring:devel -- /usr/bin/gather --use-cm "$ENV_POD_NAMESPACE"/must-gather-metrics
```

## Build a container image

1. Build the image:

```bash
make build-image
```
