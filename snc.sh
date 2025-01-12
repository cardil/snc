#!/bin/bash

export LC_ALL=C
export LANG=C

INSTALL_DIR=crc-tmp-install-data
JQ=${JQ:-jq}
OC=${OC:-oc}
YQ=${YQ:-yq}
OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL:-./openshift-install}
CRC_VM_NAME=${CRC_VM_NAME:-crc}
BASE_DOMAIN=${CRC_BASE_DOMAIN:-testing}
QUAY_REGISTRY=${QUAY_REGISTRY:-quay.io/openshift-release-dev/ocp-release}
CRC_PV_DIR="/mnt/pv-data"
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i id_rsa_crc"

# If user defined the OPENSHIFT_VERSION environment variable then use it.
# Otherwise use the tagged version if available
function get_openshift_version {
    if [ ${OPENSHIFT_VERSION} != "" ]; then
        OPENSHIFT_RELEASE_VERSION=$OPENSHIFT_VERSION
    else
        OPENSHIFT_RELEASE_VERSION=$(git describe --exact-match --tags HEAD 2>/dev/null)
    fi
}

function create_json_description {
    openshiftInstallerVersion=$(${OPENSHIFT_INSTALL} version)
    sncGitHash=$(git describe --abbrev=4 HEAD 2>/dev/null || git rev-parse --short=4 HEAD)
    echo {} | ${JQ} '.version = "1.0"' \
            | ${JQ} '.type = "snc"' \
            | ${JQ} ".buildInfo.buildTime = \"$(date -u --iso-8601=seconds)\"" \
            | ${JQ} ".buildInfo.openshiftInstallerVersion = \"${openshiftInstallerVersion}\"" \
            | ${JQ} ".buildInfo.sncVersion = \"git${sncGitHash}\"" \
            | ${JQ} ".clusterInfo.openshiftVersion = \"${OPENSHIFT_RELEASE_VERSION:-git}\"" \
            | ${JQ} ".clusterInfo.clusterName = \"${CRC_VM_NAME}\"" \
            | ${JQ} ".clusterInfo.baseDomain = \"${BASE_DOMAIN}\"" \
            | ${JQ} ".clusterInfo.appsDomain = \"apps-${CRC_VM_NAME}.${BASE_DOMAIN}\"" >${INSTALL_DIR}/crc-bundle-info.json
}

function generate_pv() {
  local pvdir="${1}"
  local name="${2}"
cat <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${name}
  labels:
    volume: ${name}
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
    - ReadWriteMany
    - ReadOnlyMany
  hostPath:
    path: ${pvdir}
  persistentVolumeReclaimPolicy: Recycle
EOF
}

function setup_pv_dirs() {
    local dir="${1}"
    local count="${2}"

    ${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} 'sudo bash -x -s' <<EOF
    for pvsubdir in \$(seq -f "pv%04g" 1 ${count}); do
        mkdir -p "${dir}/\${pvsubdir}"
    done
    if ! chcon -R -t svirt_sandbox_file_t "${dir}" &> /dev/null; then
        echo "Failed to set SELinux context on ${dir}"
    fi
    chmod -R 770 ${dir}
EOF
}

function create_pvs() {
    local pvdir="${1}"
    local count="${2}"

    setup_pv_dirs "${pvdir}" "${count}"

    for pvname in $(seq -f "pv%04g" 1 ${count}); do
        if ! ${OC} get pv "${pvname}" &> /dev/null; then
            generate_pv "${pvdir}/${pvname}" "${pvname}" | ${OC} create -f -
        else
            echo "persistentvolume ${pvname} already exists"
        fi
    done
}

get_openshift_version

# Download the oc binary if not present in current directory
if ! which $OC; then
    if [[ ! -e oc ]] ; then
        if [ "${OPENSHIFT_RELEASE_VERSION}" != "" ]; then
            curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OPENSHIFT_RELEASE_VERSION}/openshift-client-linux-${OPENSHIFT_RELEASE_VERSION}.tar.gz | tar zx oc
        else
            curl -L https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz | tar zx oc
        fi
    fi
    OC=./oc
fi

# Download yq for manipulating in place yaml configs
if ! which $YQ; then
    if [[ ! -e yq ]]; then
        curl -L https://github.com/mikefarah/yq/releases/download/2.2.1/yq_linux_amd64 -o yq
        chmod +x yq
    fi
    YQ=./yq
fi

if ! which ${JQ}; then
    sudo yum -y install /usr/bin/jq
fi

# Destroy an existing cluster and resources
${OPENSHIFT_INSTALL} --dir $INSTALL_DIR destroy cluster --log-level debug

if [ "${OPENSHIFT_PULL_SECRET}" = "" ]; then
    echo "OpenShift pull secret must be specified through the OPENSHIFT_PULL_SECRET environment variable"
    exit 1
fi

# Use the release payload for the latest known openshift release as indicated by git tags
if [ "${OPENSHIFT_RELEASE_VERSION}" != "" ]; then
    OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${QUAY_REGISTRY}:${OPENSHIFT_RELEASE_VERSION}
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE
    echo "Setting OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
fi

# Generate a new ssh keypair for this cluster
rm id_rsa_crc* || true
ssh-keygen -N "" -f id_rsa_crc -C "core"

# Set NetworkManager DNS overlay file
cat << EOF | sudo tee /etc/NetworkManager/dnsmasq.d/openshift.conf
server=/${CRC_VM_NAME}.${BASE_DOMAIN}/192.168.126.1
address=/apps-${CRC_VM_NAME}.${BASE_DOMAIN}/192.168.126.11
EOF

# Reload the NetworkManager to make DNS overlay effective
sudo systemctl reload NetworkManager

# Create the INSTALL_DIR for the installer and copy the install-config
rm -fr $INSTALL_DIR && mkdir $INSTALL_DIR && cp install-config.yaml $INSTALL_DIR
${YQ} write --inplace $INSTALL_DIR/install-config.yaml baseDomain $BASE_DOMAIN
${YQ} write --inplace $INSTALL_DIR/install-config.yaml metadata.name $CRC_VM_NAME
${YQ} write --inplace $INSTALL_DIR/install-config.yaml compute[0].replicas 0
${YQ} write --inplace $INSTALL_DIR/install-config.yaml pullSecret "${OPENSHIFT_PULL_SECRET}"
${YQ} write --inplace $INSTALL_DIR/install-config.yaml sshKey "$(cat id_rsa_crc.pub)"

# Create the manifests using the INSTALL_DIR
${OPENSHIFT_INSTALL} --dir $INSTALL_DIR create manifests || exit 1

# Copy the config which removes taint from master
cp 99_master-kubelet-no-taint.yaml $INSTALL_DIR/openshift/

# Add worker label to master machine config
${YQ} write --inplace $INSTALL_DIR/openshift/99_openshift-cluster-api_master-machines-0.yaml spec.metadata.labels[node-role.kubernetes.io/worker] ""

# Add custom domain to cluster-ingress
${YQ} write --inplace $INSTALL_DIR/manifests/cluster-ingress-02-config.yml spec[domain] apps-${CRC_VM_NAME}.${BASE_DOMAIN}

# Start the cluster with 10GB memory and 4 CPU create and wait till it finish
export TF_VAR_libvirt_master_memory=10192
export TF_VAR_libvirt_master_vcpu=4

# Add codeReadyContainer as invoker to identify it with telemeter
export OPENSHIFT_INSTALL_INVOKER="codeReadyContainers"

${OPENSHIFT_INSTALL} --dir $INSTALL_DIR create cluster --log-level debug

# Wait for install to complete, this provide another 30 mins to make resources (apis) stable
${OPENSHIFT_INSTALL} --dir $INSTALL_DIR wait-for install-complete --log-level debug
if [ $? -ne 0 ]; then
    echo "This is known to fail with:
'pool master is not ready - timed out waiting for the condition'
see https://github.com/openshift/machine-config-operator/issues/579"
fi

# Set the VM static hostname to crc-xxxxx-master-0 instead of localhost.localdomain
HOSTNAME=$(${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} hostnamectl status --transient)
${SSH} core@api.${CRC_VM_NAME}.${BASE_DOMAIN} sudo hostnamectl set-hostname ${HOSTNAME}

create_json_description

# export the kubeconfig
export KUBECONFIG=$INSTALL_DIR/auth/kubeconfig

# Create persistent volumes
create_pvs "${CRC_PV_DIR}" 30

# Once it is finished, disable the CVO
${OC} scale --replicas=0 deployment --all -n openshift-cluster-version

# Disable the deployment/replicaset/statefulset config for openshift-monitoring namespace
${OC} scale --replicas=0 deployment --all -n openshift-monitoring
${OC} scale --replicas=0 statefulset --all -n openshift-monitoring

# Delete the pods which are there in Complete state
${OC} delete pods -l 'app in (installer, pruner)' -n openshift-kube-apiserver
${OC} delete pods -l 'app in (installer, pruner)' -n openshift-kube-scheduler
${OC} delete pods -l 'app in (installer, pruner)' -n openshift-kube-controller-manager

# Disable the deployment/replicaset for openshift-machine-api and openshift-machine-config-operator
${OC} scale --replicas=0 deployment --all -n openshift-machine-api
${OC} scale --replicas=0 deployment --all -n openshift-machine-config-operator

# Scale route deployment from 2 to 1
${OC} patch --patch='{"spec": {"replicas": 1}}' --type=merge ingresscontroller/default -n openshift-ingress-operator

# Set default route for registry CRD from false to true.
${OC} patch config.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge

# Delete the v1beta1.metrics.k8s.io apiservice since we are already scale down cluster wide monitioring.
# Since this CRD block namespace deletion forever.
${OC} delete apiservice v1beta1.metrics.k8s.io
