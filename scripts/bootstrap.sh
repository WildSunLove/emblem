#!/bin/bash
set -eu

_error_report() {
  echo >&2 "Exited [$?] at line $(caller):"
  cat -n $0 | tail -n+$(($1 - 3)) | head -n7 | sed "4s/^\s*/>>> /"
}
trap '_error_report $LINENO' ERR

# Formatting variables
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Check env variables are not empty strings
if [[ -z "${PROD_PROJECT:-}" ]]; then
    echo -e "---\n${RED}Emblem bootstrap error:${NC} Please set the $(tput bold)PROD_PROJECT$(tput sgr0) environment variable \n---"
    exit 1
elif [[ -z "${STAGE_PROJECT:-}" ]]; then
    echo -e "---\n${RED}Emblem bootstrap error:${NC} Please set the $(tput bold)STAGE_PROJECT$(tput sgr0) environment variable \n---"
    exit 1
elif [[ -z "${OPS_PROJECT:-}" ]]; then
    echo -e "---\n${RED}Emblem bootstrap error:${NC} Please set the $(tput bold)OPS_PROJECT$(tput sgr0) environment variable \n---"
    exit 1
fi

echo -e "Bootstrapping Emblem...\n"

# Set other variables
OPS_PROJECT_NUMBER=$(gcloud projects list --format='value(PROJECT_NUMBER)' --filter=PROJECT_ID=$OPS_PROJECT)
if [[ -z "${OPS_PROJECT_NUMBER}" ]]; then
    echo -e "---\n${RED}Emblem bootstrap error:${NC} Could not retrieve project number for $(tput bold)${OPS_PROJECT}$(tput sgr0).\n---"
    exit 1
fi

EMBLEM_TF_SERVICE_ACCOUNT=emblem-terraformer@${OPS_PROJECT}.iam.gserviceaccount.com
BUILD_SERVICE_ACCOUNT=${OPS_PROJECT_NUMBER}@cloudbuild.gserviceaccount.com
REPO_CONNECT_URL="https://console.cloud.google.com/cloud-build/triggers/connect?project=${OPS_PROJECT}"
STATE_GCS_BUCKET_NAME="$OPS_PROJECT-tf-states"
OPS_IAM="bindings:
- members:
  - serviceAccount:${EMBLEM_TF_SERVICE_ACCOUNT}
  role: roles/cloudbuild.builds.editor
- members:
  - serviceAccount:${EMBLEM_TF_SERVICE_ACCOUNT}
  role: roles/secretmanager.admin
- members:
  - serviceAccount:${EMBLEM_TF_SERVICE_ACCOUNT}
  role: roles/pubsub.editor
- members:
  - serviceAccount:${EMBLEM_TF_SERVICE_ACCOUNT}
  role: roles/iam.serviceAccountAdmin
- members:
  - serviceAccount:${EMBLEM_TF_SERVICE_ACCOUNT}
  role: roles/artifactregistry.admin
- members:
  - serviceAccount:${EMBLEM_TF_SERVICE_ACCOUNT}
  role: roles/resourcemanager.projectIamAdmin
- members:
  - serviceAccount:${EMBLEM_TF_SERVICE_ACCOUNT}
  role: roles/cloudscheduler.admin
- members:
  - serviceAccount:${EMBLEM_TF_SERVICE_ACCOUNT}
  role: roles/serviceusage.serviceUsageAdmin"
APP_IAM="bindings:
- members:
  - serviceAccount:${EMBLEM_TF_SERVICE_ACCOUNT}
  role: roles/serviceusage.serviceUsageAdmin
- members:
  - serviceAccount:${EMBLEM_TF_SERVICE_ACCOUNT}
  role: roles/storage.admin
- members:
  - serviceAccount:${EMBLEM_TF_SERVICE_ACCOUNT}
  role: roles/resourcemanager.projectIamAdmin
- members:
  - serviceAccount:${EMBLEM_TF_SERVICE_ACCOUNT}
  role: roles/iam.serviceAccountAdmin
- members:
  - serviceAccount:${EMBLEM_TF_SERVICE_ACCOUNT}
  role: roles/run.developer
- members:
  - serviceAccount:${EMBLEM_TF_SERVICE_ACCOUNT}
  role: roles/firebase.managementServiceAgent"

# Services needed for Terraform to manage resources via service account 

echo -e "\n\xe2\x88\xb4 Enabling initial required services... "
gcloud services enable --project $OPS_PROJECT --async \
    iamcredentials.googleapis.com \
    cloudresourcemanager.googleapis.com \
    compute.googleapis.com \
    serviceusage.googleapis.com \
    appengine.googleapis.com \
    cloudbuild.googleapis.com > /dev/null

# Create terraform service account
if gcloud iam service-accounts describe \
    $EMBLEM_TF_SERVICE_ACCOUNT \
    --project $OPS_PROJECT &> /dev/null ; then
        echo -e "\n\xe2\x88\xb4 Using existing Emblem Terraform service account:  $EMBLEM_TF_SERVICE_ACCOUNT "
else
    echo -e "\n\xe2\x88\xb4 Creating Emblem Terraform service account: $EMBLEM_TF_SERVICE_ACCOUNT "
    gcloud iam service-accounts create emblem-terraformer \
        --project="$OPS_PROJECT" \
        --description="Service account for deploying resources via Terraform" \
        --display-name="Emblem Terraformer"
fi

# Give cloud build service account token creator on terraform service account policy
echo -e "\n\xe2\x88\xb4 Updating Terraform service account IAM policy... "
gcloud iam service-accounts add-iam-policy-binding --project=$OPS_PROJECT \
    $EMBLEM_TF_SERVICE_ACCOUNT \
    --member="serviceAccount:${BUILD_SERVICE_ACCOUNT}" \
    --role="roles/iam.serviceAccountTokenCreator" &> /dev/null

# Ops permissions
echo -e "\n\xe2\x88\xb4 Updating ops project IAM policy... "

OPS_CURRENT_IAM=$(gcloud projects get-iam-policy $OPS_PROJECT --format=yaml | tail -n +2)

echo -e "${OPS_IAM}\n${OPS_CURRENT_IAM}" | \
    gcloud projects set-iam-policy $OPS_PROJECT /dev/stdin > /dev/null

# App permissions for stage and prod

echo -e "\n\xe2\x88\xb4 Updating stage project IAM policy... "

STAGE_CURRENT_IAM=$(gcloud projects get-iam-policy $STAGE_PROJECT --format=yaml | tail -n +2)

echo -e "${APP_IAM}\n${STAGE_CURRENT_IAM}" | \
    gcloud projects set-iam-policy $STAGE_PROJECT /dev/stdin > /dev/null

echo -e "\n\xe2\x88\xb4 Updating prod project IAM policy... "
PROD_CURRENT_IAM=$(gcloud projects get-iam-policy $PROD_PROJECT --format=yaml | tail -n +2)
echo -e "${APP_IAM}\n${PROD_CURRENT_IAM}" | \
    gcloud projects set-iam-policy $PROD_PROJECT /dev/stdin > /dev/null

# Setup Terraform state bucket

if gcloud storage buckets list gs://$STATE_GCS_BUCKET_NAME --project $OPS_PROJECT &> /dev/null ; then
    echo -e "\n\xe2\x88\xb4 Using existing Terraform remote state bucket: gs://${STATE_GCS_BUCKET_NAME} "
    gcloud storage buckets update gs://$STATE_GCS_BUCKET_NAME --versioning --project $OPS_PROJECT > /dev/null
else
    echo -e "\n\xe2\x88\xb4 Creating Terraform remote state bucket: gs://${STATE_GCS_BUCKET_NAME} "
    gcloud storage buckets create gs://${STATE_GCS_BUCKET_NAME} --project=$OPS_PROJECT > /dev/null
    echo -e "\n\xe2\x88\xb4 Enabling versioning... "
    gcloud storage buckets update gs://$STATE_GCS_BUCKET_NAME --versioning --project $OPS_PROJECT > /dev/null
fi

echo -e "\n\xe2\x88\xb4 Setting storage bucket IAM policy for Terraform service account..."
# Note: `gcloud storage buckets` does not support `add-iam-policy-binding` in 
# Google Cloud SDK 410.0.0 (current default in Cloud Shell).
gsutil iam ch serviceAccount:${EMBLEM_TF_SERVICE_ACCOUNT}:admin \
  gs://${STATE_GCS_BUCKET_NAME}

# Add GitHub repo to ops project
echo -e "\n${GREEN}\xE2\x9E\xA8 Connect a fork of the Emblem GitHub repo to your ops project via the Cloud Console:${NC} $(tput bold)${REPO_CONNECT_URL}$(tput sgr0) \n"
read -n 1 -r -s -p $'Once your forked Emblem repo is connected, please type any key to continue.\n'

continue=1
while [[ ${continue} -gt 0 ]]; do
    read -rp "Please input the GitHub repository owner: " REPO_OWNER
    read -rp "Please input the GitHub repository name: " REPO_NAME
    echo -e "\n"
    read -rp "Is this the correct repository URL? $(tput bold)https://github.com/${REPO_OWNER}/${REPO_NAME}$(tput sgr0)? (Y/n) " yesno

    case "$yesno" in
    [yY][eE][sS]|[yY]|"") 
        continue=0
        ;;
    *)
        continue=1
        ;;
    esac
done

echo -e "\n\xe2\x88\xb4 Adding repo information to project metadata... "

# Values for repo owner and name are stored in project metadata. Wait for 
# the service to finish enabling before continuing.

while [[ ! $(gcloud services list --project=$OPS_PROJECT \
    --format="value[](config.name)" \
    --filter=config.name:compute.googleapis.com) ]]
    do
        echo -e "\xe2\x88\xb4 Waiting for services... "
        sleep 5
    done
gcloud compute project-info add-metadata --project=$OPS_PROJECT \
    --metadata=REPO_NAME=$REPO_NAME > /dev/null

gcloud compute project-info add-metadata --project=$OPS_PROJECT \
    --metadata=REPO_OWNER=$REPO_OWNER > /dev/null

echo -e "\n${GREEN}Emblem bootstrapping complete! Please run setup.sh${NC} \n"
