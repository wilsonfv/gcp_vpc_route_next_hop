#!/bin/bash

function log()  {
    STAMP=$(date +'%Y-%m-%d %H:%M:%S %Z')
    printf "\n%s    %s\n" "${STAMP}" "$1"
}

function tidy_up() {
    for VPC_NAME in $(gcloud compute networks list \
                        --project=${GCP_PROJECT_ID} \
                        --format="value(NAME)" \
                        --filter="name=(${VPC_NAME_1})")
    do
        if [[ $(gcloud compute routes list --filter="name=${ROUTE_NAME}") ]]; then
            gcloud compute routes delete ${ROUTE_NAME} -q
        fi

        if [[ $( gcloud compute health-checks list --project=${GCP_PROJECT_ID} --filter="NAME=hc-tcp-9999" ) ]]; then
            gcloud compute forwarding-rules delete ${FR_NAME} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} -q
            gcloud compute backend-services delete ${BE_NAME} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} -q
            gcloud compute health-checks delete ${HC_NAME} --region=${GCP_REGION} --project=${GCP_PROJECT_ID} -q
        fi

        for SUBNET_REGION in $(gcloud compute networks subnets list \
                                --network=${VPC_NAME} \
                                --project=${GCP_PROJECT_ID} \
                                --format="csv(NAME,REGION)[no-heading]")
        do
            SUBNET=$(echo -n "${SUBNET_REGION}" | cut -d, -f1)
            REGION=$(echo -n "${SUBNET_REGION}" | cut -d, -f2)
            gcloud compute networks subnets delete ${SUBNET} --region ${REGION} -q
        done

        gcloud compute networks delete ${VPC_NAME} --project=${GCP_PROJECT_ID} -q
    done
}

function get_tf_binary() {
    ROOT_DIR=$1
    PRODUCT=$2
    PRODUCT_VERSION=$3
    OS_VERSION=$4

    FILE_NAME=${PRODUCT}_${PRODUCT_VERSION}_${OS_VERSION}.zip
    URL=https://releases.hashicorp.com/${PRODUCT}/${PRODUCT_VERSION}/${FILE_NAME}

    log "downloading ${URL}"
    curl -k -s ${URL} \
        -o ${ROOT_DIR}/${FILE_NAME}

    unzip -q -o ${ROOT_DIR}/${FILE_NAME} -d ${ROOT_DIR}
    rm -f ${ROOT_DIR}/${FILE_NAME}
}

# **********************************************************************************************
# Main Flow
# **********************************************************************************************

set -e

export SCRIPT_DIR=$(dirname "$0")
export TF_BINARY_DIR=${SCRIPT_DIR}/tf_binary

log "download terraform binary"
if [[ -d ${TF_BINARY_DIR} ]]; then
    rm -rf ${TF_BINARY_DIR}
fi
mkdir -p ${TF_BINARY_DIR}
get_tf_binary ${TF_BINARY_DIR} terraform                        0.12.13 darwin_amd64
get_tf_binary ${TF_BINARY_DIR} terraform-provider-google        2.17.0 darwin_amd64
get_tf_binary ${TF_BINARY_DIR} terraform-provider-google-beta   2.17.0 darwin_amd64
get_tf_binary ${TF_BINARY_DIR} terraform-provider-google        3.10.0 darwin_amd64

log "terraform version"
${TF_BINARY_DIR}/terraform version

log "list terraform binary and providers"
ls -l ${TF_BINARY_DIR}

export GCP_PROJECT_ID=$(gcloud config list --format='value(core.project)')

if [[ ! -f ${GOOGLE_APPLICATION_CREDENTIALS} ]]; then
    log "Environment variable GOOGLE_APPLICATION_CREDENTIALS is not defined or file ${GOOGLE_APPLICATION_CREDENTIALS} does not exist"
    exit 1
fi
gcloud auth activate-service-account --key-file ${GOOGLE_APPLICATION_CREDENTIALS}


export GCP_PROJECT_ID=$(gcloud config list --format='value(core.project)')
export GCP_SERVICE_ACCOUNT=$(gcloud config list --format='value(core.account)')

export VPC_NAME_1="vpc1"
export GCP_REGION="asia-east2"
export SUBNET_NAME_1="${VPC_NAME_1}-${GCP_REGION}"
export ROUTE_NAME="route-ilb"
export HC_NAME="hc-tcp-9999"
export BE_NAME="be-ilb"
export FR_NAME="fr-ilb-nat"
export NEXT_HOP_ILB_URL="regions/${GCP_REGION}/forwardingRules/${FR_NAME}"

log "clean up environment"
tidy_up

log "create a VPC"
gcloud compute networks create ${VPC_NAME_1} \
    --project=${GCP_PROJECT_ID} \
    --bgp-routing-mode="regional" \
    --subnet-mode=custom

log "create a subnet"
gcloud compute networks subnets create ${SUBNET_NAME_1} \
    --network=${VPC_NAME_1} \
    --range=192.168.0.0/16 \
    --region=${GCP_REGION}

log "list vpc and subnet"
gcloud compute networks list --project=${GCP_PROJECT_ID} --format="table(name,selfLink)"
gcloud compute networks subnets list --network=${VPC_NAME_1} --project=${GCP_PROJECT_ID} --format="table(name,selfLink)"

log "create heath-check, backend and forwarding rule"
gcloud compute health-checks create tcp ${HC_NAME} --region=${GCP_REGION} --port=9999
gcloud compute backend-services create ${BE_NAME} \
    --load-balancing-scheme=internal \
    --protocol=tcp \
    --region=${GCP_REGION} \
    --health-checks=${HC_NAME} \
    --health-checks-region=${GCP_REGION}
gcloud compute forwarding-rules create ${FR_NAME} \
    --region=${GCP_REGION} \
    --load-balancing-scheme=internal \
    --network=${VPC_NAME_1} \
    --subnet=${SUBNET_NAME_1} \
    --ip-protocol=TCP \
    --ports=ALL \
    --backend-service=${BE_NAME} \
    --backend-service-region=${GCP_REGION}

log "clean up terraform dir"
if [[ -d ${SCRIPT_DIR}/.terraform ]]; then
    rm -rf ${SCRIPT_DIR}/.terraform
fi

log "prepare main.tf"
cat >${SCRIPT_DIR}/main.tf<<EOF
provider "google" {
  alias  = "v3"
  version = ">= 3.10.0"
}

resource "google_compute_route" "${ROUTE_NAME}" {
  provider = google.v3

  name         = "${ROUTE_NAME}"
  dest_range   = "128.0.0.0/2"
  network      = var.network_name
  project      = var.project
  next_hop_ilb = var.next_hop_ilb_url
  priority     = 1000
}
EOF
cat ${SCRIPT_DIR}/main.tf

log "prepare vars.tf"
cat >${SCRIPT_DIR}/vars.tf<<EOF
variable "project" {
  description = "project ID"
  type        = string
}

variable "network_name" {
  description = "vpc network name"
  type        = string
}

variable "next_hop_ilb_url" {
  description = "next hop ilb url"
  type        = string
}
EOF
cat ${SCRIPT_DIR}/vars.tf

log "terraform init"
${TF_BINARY_DIR}/terraform init ${SCRIPT_DIR}

log "terraform apply"
${TF_BINARY_DIR}/terraform apply \
    -var="project=${GCP_PROJECT_ID}" \
    -var="network_name=${VPC_NAME_1}" \
    -var="next_hop_ilb_url=${NEXT_HOP_ILB_URL}" \
    -auto-approve \
    ${SCRIPT_DIR}

log "list forwarding rule and vpc route"
gcloud compute forwarding-rules list --project=${GCP_PROJECT_ID}
gcloud compute routes list --project=${GCP_PROJECT_ID}

log "clean up environment"
tidy_up
