#!/bin/bash
# Copyright 2023 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
print_info "Checking prerequisites..."
if ! command_exists gcloud; then
    print_error "gcloud CLI is not installed. Please install it from https://cloud.google.com/sdk/docs/install"
    exit 1
fi

# Get project configuration
if [ -z "$PROJECT_ID" ]; then
    read -p "Enter GCP Project ID: " PROJECT_ID
fi

if [ -z "$ZONE" ]; then
    read -p "Enter GCP Zone (default: us-central1-c): " ZONE
    ZONE=${ZONE:-us-central1-c}
fi

if [ -z "$REGION" ]; then
    REGION=$(echo "$ZONE" | rev | cut -d'-' -f2- | rev)
fi

if [ -z "$BUCKET_NAME" ]; then
    read -p "Enter GCS bucket name for STIG artifacts (default: ${PROJECT_ID}-stig-artifacts): " BUCKET_NAME
    BUCKET_NAME=${BUCKET_NAME:-${PROJECT_ID}-stig-artifacts}
fi

if [ -z "$CLOUDBUILD_BUCKET" ]; then
    CLOUDBUILD_BUCKET="${PROJECT_ID}_cloudbuild"
fi

print_info "Configuration:"
print_info "  Project ID: $PROJECT_ID"
print_info "  Zone: $ZONE"
print_info "  Region: $REGION"
print_info "  STIG Artifacts Bucket: $BUCKET_NAME"
print_info "  Cloud Build Bucket: $CLOUDBUILD_BUCKET"
echo ""

read -p "Continue with this configuration? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_warn "Setup cancelled."
    exit 0
fi

# Set the project
print_info "Setting active project to $PROJECT_ID..."
gcloud config set project "$PROJECT_ID"

# Get project number
print_info "Retrieving project number..."
PROJECT_NUMBER=$(gcloud projects list --filter="$PROJECT_ID" --format="value(PROJECT_NUMBER)")
print_info "  Project Number: $PROJECT_NUMBER"

# Enable required APIs
print_info "Enabling required APIs..."
gcloud services enable \
    cloudbuild.googleapis.com \
    compute.googleapis.com \
    iap.googleapis.com \
    cloudkms.googleapis.com \
    artifactregistry.googleapis.com \
    containerregistry.googleapis.com \
    storage.googleapis.com \
    --project="$PROJECT_ID"

print_info "APIs enabled successfully."

# Create default VPC network if it doesn't exist
print_info "Checking for default VPC network..."
if gcloud compute networks describe default --project="$PROJECT_ID" >/dev/null 2>&1; then
    print_warn "Default VPC network already exists. Skipping creation."
else
    print_info "Creating default VPC network..."
    gcloud compute networks create default \
        --subnet-mode=auto \
        --bgp-routing-mode=regional \
        --project="$PROJECT_ID" \
        --quiet
    print_info "Default VPC network created."
fi

# Create firewall rule for IAP SSH access
print_info "Creating firewall rule for IAP SSH access..."
if gcloud compute firewall-rules describe allow-iap-ssh --project="$PROJECT_ID" >/dev/null 2>&1; then
    print_warn "Firewall rule 'allow-iap-ssh' already exists. Skipping creation."
else
    gcloud compute firewall-rules create allow-iap-ssh \
        --network=default \
        --allow=tcp:22 \
        --source-ranges=35.235.240.0/20 \
        --project="$PROJECT_ID" \
        --description="Allow SSH from IAP" \
        --quiet
    print_info "Firewall rule created."
fi

# Create Packer service account
print_info "Creating Packer service account..."
if gcloud iam service-accounts describe "packer@${PROJECT_ID}.iam.gserviceaccount.com" >/dev/null 2>&1; then
    print_warn "Packer service account already exists. Skipping creation."
else
    gcloud iam service-accounts create packer \
        --project="$PROJECT_ID" \
        --description="Packer Service Account" \
        --display-name="Packer Service Account"
    print_info "Packer service account created."
fi

# Grant IAM roles to Packer service account
print_info "Granting IAM roles to Packer service account..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:packer@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role=roles/compute.instanceAdmin.v1 \
    --condition=None \
    --quiet

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:packer@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role=roles/iam.serviceAccountUser \
    --condition=None \
    --quiet

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:packer@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role=roles/iap.tunnelResourceAccessor \
    --condition=None \
    --quiet

print_info "Packer service account IAM roles granted."

# Grant IAM roles to Cloud Build service account
print_info "Granting IAM roles to Cloud Build service account..."
gcloud iam service-accounts add-iam-policy-binding \
    "packer@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --quiet

gcloud iam service-accounts add-iam-policy-binding \
    "packer@${PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --quiet

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --role=roles/iap.tunnelResourceAccessor \
    --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --condition=None \
    --quiet

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --role=roles/artifactregistry.writer \
    --condition=None \
    --quiet

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --role=roles/storage.objectAdmin \
    --condition=None \
    --quiet

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --role=roles/compute.instanceAdmin.v1 \
    --condition=None \
    --quiet

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role=roles/compute.instanceAdmin.v1 \
    --condition=None \
    --quiet

# Grant the compute service account the ability to use itself
gcloud iam service-accounts add-iam-policy-binding \
    "${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role=roles/iam.serviceAccountUser \
    --quiet

# Grant the compute service account IAP tunnel access
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role=roles/iap.tunnelResourceAccessor \
    --condition=None \
    --quiet

# Grant the compute service account Cloud Logging write access
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role=roles/logging.logWriter \
    --condition=None \
    --quiet

print_info "Cloud Build service account IAM roles granted."

# Create KMS keyring and key
print_info "Creating KMS keyring and encryption key..."
if gcloud kms keyrings describe stig-artifacts --location="$REGION" >/dev/null 2>&1; then
    print_warn "KMS keyring 'stig-artifacts' already exists. Skipping creation."
else
    gcloud kms keyrings create stig-artifacts --location="$REGION" --quiet
    print_info "KMS keyring created."
fi

if gcloud kms keys describe storage-key --location="$REGION" --keyring=stig-artifacts >/dev/null 2>&1; then
    print_warn "KMS key 'storage-key' already exists. Skipping creation."
else
    gcloud kms keys create storage-key \
        --location="$REGION" \
        --keyring=stig-artifacts \
        --purpose=encryption \
        --quiet
    print_info "KMS encryption key created."
fi

# Authorize Cloud Storage to use the KMS key
print_info "Authorizing Cloud Storage service to use KMS key..."
gsutil kms authorize \
    -k "projects/${PROJECT_ID}/locations/${REGION}/keyRings/stig-artifacts/cryptoKeys/storage-key" \
    -p "$PROJECT_ID"

# Grant Compute Engine service account access to KMS key
print_info "Granting Compute Engine service account access to KMS key..."
gcloud kms keys add-iam-policy-binding storage-key \
    --location="$REGION" \
    --keyring=stig-artifacts \
    --member="serviceAccount:service-${PROJECT_NUMBER}@compute-system.iam.gserviceaccount.com" \
    --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
    --quiet

# Create GCS bucket for STIG artifacts
print_info "Creating GCS bucket for STIG artifacts..."
if gsutil ls -p "$PROJECT_ID" "gs://${BUCKET_NAME}" >/dev/null 2>&1; then
    print_warn "Bucket 'gs://${BUCKET_NAME}' already exists. Skipping creation."
else
    gcloud storage buckets create "gs://${BUCKET_NAME}" \
        --project="$PROJECT_ID" \
        --location="$REGION" \
        --uniform-bucket-level-access \
        --default-encryption-key="projects/${PROJECT_ID}/locations/${REGION}/keyRings/stig-artifacts/cryptoKeys/storage-key"
    print_info "STIG artifacts bucket created."
fi

# Create Cloud Build staging bucket
print_info "Creating Cloud Build staging bucket..."
if gsutil ls -p "$PROJECT_ID" "gs://${CLOUDBUILD_BUCKET}" >/dev/null 2>&1; then
    print_warn "Bucket 'gs://${CLOUDBUILD_BUCKET}' already exists. Skipping creation."
else
    gcloud storage buckets create "gs://${CLOUDBUILD_BUCKET}" \
        --project="$PROJECT_ID" \
        --location="$REGION" \
        --uniform-bucket-level-access \
        --default-encryption-key="projects/${PROJECT_ID}/locations/${REGION}/keyRings/stig-artifacts/cryptoKeys/storage-key"
    print_info "Cloud Build bucket created."
fi

# Grant Cloud Build service accounts access to Cloud Build bucket
print_info "Granting Cloud Build service accounts access to staging bucket..."
gcloud storage buckets add-iam-policy-binding "gs://${CLOUDBUILD_BUCKET}" \
    --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --role=roles/storage.admin \
    --quiet

gcloud storage buckets add-iam-policy-binding "gs://${CLOUDBUILD_BUCKET}" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role=roles/storage.admin \
    --quiet

# Grant compute service account access to STIG artifacts bucket
print_info "Granting compute service account access to STIG artifacts bucket..."
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role=roles/storage.objectAdmin \
    --quiet

# Create Artifact Registry repository
print_info "Creating Artifact Registry repository..."
if gcloud artifacts repositories describe gcr.io --location=us >/dev/null 2>&1; then
    print_warn "Artifact Registry repository 'gcr.io' already exists. Skipping creation."
else
    gcloud artifacts repositories create gcr.io \
        --repository-format=docker \
        --location=us \
        --description="GCR repository for container images" \
        --quiet
    print_info "Artifact Registry repository created."
fi

# Grant Cloud Build service accounts write access to Artifact Registry
print_info "Granting Cloud Build service accounts write access to Artifact Registry..."
gcloud artifacts repositories add-iam-policy-binding gcr.io \
    --location=us \
    --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
    --role=roles/artifactregistry.writer \
    --quiet

gcloud artifacts repositories add-iam-policy-binding gcr.io \
    --location=us \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role=roles/artifactregistry.writer \
    --quiet

print_info "Artifact Registry permissions granted."

# Summary
echo ""
print_info "============================================"
print_info "Setup completed successfully!"
print_info "============================================"
echo ""
print_info "Project Configuration:"
print_info "  Project ID: $PROJECT_ID"
print_info "  Project Number: $PROJECT_NUMBER"
print_info "  Zone: $ZONE"
print_info "  Region: $REGION"
echo ""
print_info "Resources Created:"
print_info "  ✓ Packer service account: packer@${PROJECT_ID}.iam.gserviceaccount.com"
print_info "  ✓ KMS keyring: projects/${PROJECT_ID}/locations/${REGION}/keyRings/stig-artifacts"
print_info "  ✓ KMS key: projects/${PROJECT_ID}/locations/${REGION}/keyRings/stig-artifacts/cryptoKeys/storage-key"
print_info "  ✓ STIG artifacts bucket: gs://${BUCKET_NAME}"
print_info "  ✓ Cloud Build bucket: gs://${CLOUDBUILD_BUCKET}"
print_info "  ✓ Artifact Registry repository: us-docker.pkg.dev/${PROJECT_ID}/gcr.io"
echo ""
print_info "Next Steps:"
print_info "  1. Update Makefile with project configuration"
print_info "  2. Run 'make builder' to build the Packer container image"
print_info "  3. Run 'make rebuild' to build and evaluate STIG-compliant images"
echo ""
