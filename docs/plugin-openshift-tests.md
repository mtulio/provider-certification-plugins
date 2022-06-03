# openshift-tests plugin

## CSI certification

> Limited to certify one StorageClass at time

Steps to run CSI certification as plugins:

1. Create the driver capabilities config map `openshift-provider-certification-csi/driver-test-spec/manifest.yaml`:

```bash
oc create ns openshift-provider-certification-csi
oc create configmap driver-test-spec \
    -n openshift-provider-certification-csi \
    --from-file=manifest.yaml=tools/openshift-provider-cert-plugin/hack/csi-samples/csi-cert-aws-setup-ebs.yaml
```

2. Run the certification tool setting the StorageClass name related to ConfigMap created on the last step setting the variable `STORAGE_CLASS`

```bash
STORAGE_CLASS=gp2 ./openshift-provider-cert run \
    --sonobuoy-image "quay.io/mrbraga/sonobuoy:v0.56.6" \
    -w --dedicated
```

3. Wait the tests to be finished, and results be collected

```bash

```

4. Check the results

```bash
./openshift-provider-cert results
```


### Troubleshooting steps:

- Get the pod name related to CSI

```bash
oc get pods -n openshift-provider-certification
```

- Check the logs, for example:

```bash
oc logs sonobuoy-openshift-csi-certification-job-03da8b41a07f4e09 \
    -n openshift-provider-certification -c plugin -f
```

1. Make sure you can see the CSI tests backend has been started:

```
#./executor.sh:36>  Starting setup CSI certification...
#./executor.sh:38>  Getting CSI driver configuration from ConfigMap
#./executor.sh:39>   Namespace[openshift-provider-certification-csi] ConfigMap[driver-test-spec] Key=[manifest.yaml]
manifest.yaml
#./executor.sh:44>  Getting StorageClass [gp2] manifest
#./executor.sh:47>  Running openshift-tests suite [openshift/csi] for CSI Certification...
Jun  3 21:13:09.693: INFO: Driver loaded from path [/ocp-conformance/manifest.yaml]: (...)
```
