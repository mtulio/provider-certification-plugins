# OCI
export PROVIDER_NAME=oci
export REPOSITORY_URL=https://github.com/oracle/oci-cloud-controller-manager.git
export VERSION=v1.29.0
export WORKDIR=/tmp/shared
export PATH=$PATH:/usr/local/go/bin
export PATH=$PATH:$(go env GOROOT)/bin
export PATH=$PATH:$HOME/go/bin

export CLOUD_CONFIG=/tmp/env
curl -s https://raw.githubusercontent.com/oracle/oci-cloud-controller-manager/master/manifests/provider-config-example.yaml > ${CLOUD_CONFIG}
curl -s https://raw.githubusercontent.com/oracle/oci-cloud-controller-manager/master/manifests/provider-config-example.yaml > ${CLOUD_CONFIG}
export KUBECONFIG=/tmp/shared/kubeconfig
export CLUSTER_KUBECONFIG=$KUBECONFIG

#export RESERVED_IP=""
#export CLOUD_CONFIG=$HOME/cloudconfig
export ADLOCATION="IqDk:US-ASHBURN-AD-1"
export NSG_OCIDS="ocid1.networksecuritygroup.relm.region.aa...aa"
export BACKEND_NSG_OCIDS="ocid1.networksecuritygroup.relm.region.aa...aa"
export FSS_VOLUME_HANDLE="xx"

export MNT_TARGET_ID="id"
export MNT_TARGET_SUBNET_ID="id"
export MNT_TARGET_COMPARTMENT_ID="id"
export ENABLE_PARALLEL_RUN=true

# AWS

export PROVIDER_NAME=aws
export REPOSITORY_URL=https://github.com/kubernetes/cloud-provider-aws.git
export VERSION=v1.31.0
export WORKDIR=/tmp/shared
export PATH=$PATH:/usr/local/go/bin
export PATH=$PATH:$(go env GOROOT)/bin
export KUBECONFIG=/tmp/shared/kubeconfig
