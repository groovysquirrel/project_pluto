#!/bin/bash

# ==============================================================================
# PROJECT PLUTO - AWS Deployment Script
# ==============================================================================
#
# Deploys the AWS stack with Terraform and pushes images to ECR.
#
# REQUIREMENTS:
#   - AWS CLI configured (aws configure)
#   - Terraform installed
#   - Docker installed and running
#
# ==============================================================================

set -e

# ------------------------------------------------------------------------------
# SETTINGS
# ------------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

# ------------------------------------------------------------------------------
# HELPER FUNCTIONS
# ------------------------------------------------------------------------------

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ ERROR: $1${NC}"
    exit 1
}

# ------------------------------------------------------------------------------
# STEP 1: PREREQUISITES
# ------------------------------------------------------------------------------

print_header "STEP 1: Checking Prerequisites"

if ! command -v aws &> /dev/null; then
    print_error "AWS CLI not found. Install it first: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
fi
print_success "AWS CLI is installed"

if ! command -v terraform &> /dev/null; then
    print_error "Terraform not found. Install it first: https://developer.hashicorp.com/terraform/downloads"
fi
print_success "Terraform is installed"

if ! command -v docker &> /dev/null; then
    print_error "Docker not found. Install Docker Desktop and try again."
fi
print_success "Docker is installed"

if ! docker info &> /dev/null; then
    print_error "Docker daemon is not running. Start Docker Desktop and try again."
fi
print_success "Docker is running"

# ------------------------------------------------------------------------------
# STEP 2: COLLECT INPUTS
# ------------------------------------------------------------------------------

print_header "STEP 2: Route53 Inputs"

read -r -p "Route53 hosted zone (example.com): " HOSTED_ZONE_NAME
if [ -z "$HOSTED_ZONE_NAME" ]; then
    print_error "Hosted zone name is required."
fi

read -r -p "Optional subdomain prefix (press enter for none): " SUBDOMAIN_PREFIX

DOMAIN_ROOT="$HOSTED_ZONE_NAME"
if [ -n "$SUBDOMAIN_PREFIX" ]; then
    DOMAIN_ROOT="${SUBDOMAIN_PREFIX}.${HOSTED_ZONE_NAME}"
fi

print_info "Using domain root: ${DOMAIN_ROOT}"

ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name "$HOSTED_ZONE_NAME" \
    --query "HostedZones[?Name=='${HOSTED_ZONE_NAME}.'] | [0].Id" \
    --output text)

if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
    print_error "Hosted zone ${HOSTED_ZONE_NAME} not found in Route53. Please create it first."
fi
print_success "Route53 hosted zone verified"

# ------------------------------------------------------------------------------
# STEP 3: TERRAFORM APPLY
# ------------------------------------------------------------------------------

print_header "STEP 3: Provisioning AWS Infrastructure"

TF_DIR="${SCRIPT_DIR}/terraform"

TF_VAR_hosted_zone_name="$HOSTED_ZONE_NAME" \
TF_VAR_subdomain_prefix="$SUBDOMAIN_PREFIX" \
terraform -chdir="$TF_DIR" init

TF_VAR_hosted_zone_name="$HOSTED_ZONE_NAME" \
TF_VAR_subdomain_prefix="$SUBDOMAIN_PREFIX" \
terraform -chdir="$TF_DIR" apply

print_success "Terraform apply complete"

# ------------------------------------------------------------------------------
# STEP 4: PUSH IMAGES TO ECR
# ------------------------------------------------------------------------------

print_header "STEP 4: Pushing Images to ECR"

REGION=$(terraform -chdir="$TF_DIR" output -raw region)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
IMAGE_TAG="${IMAGE_TAG:-latest}"

print_info "Logging in to ECR (${REGION})"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

read -r TRAEFIK_REPO OPENWEBUI_REPO LITELLM_REPO CHROMADB_REPO OLLAMA_REPO <<EOF_REPOS
$(TF_DIR="$TF_DIR" python - <<'PY'
import json
import subprocess
import os

data = json.loads(subprocess.check_output([
    "terraform",
    f"-chdir={os.environ['TF_DIR']}",
    "output",
    "-json",
    "ecr_repository_urls",
]).decode())

print(data["traefik"], data["openwebui"], data["litellm"], data["chromadb"], data["ollama"])
PY
)
EOF_REPOS

print_info "Building Traefik image with domain ${DOMAIN_ROOT}"
docker build \
    --build-arg "PLUTO_DOMAIN=${DOMAIN_ROOT}" \
    -t "${TRAEFIK_REPO}:${IMAGE_TAG}" \
    "${SCRIPT_DIR}/traefik"

print_info "Pulling and pushing public images"
docker pull ghcr.io/open-webui/open-webui:main
docker tag ghcr.io/open-webui/open-webui:main "${OPENWEBUI_REPO}:${IMAGE_TAG}"


docker pull ghcr.io/berriai/litellm:main-latest
docker tag ghcr.io/berriai/litellm:main-latest "${LITELLM_REPO}:${IMAGE_TAG}"


docker pull ghcr.io/chroma-core/chroma:latest
docker tag ghcr.io/chroma-core/chroma:latest "${CHROMADB_REPO}:${IMAGE_TAG}"


docker pull ollama/ollama:latest
docker tag ollama/ollama:latest "${OLLAMA_REPO}:${IMAGE_TAG}"

print_info "Pushing images to ECR"
docker push "${TRAEFIK_REPO}:${IMAGE_TAG}"
docker push "${OPENWEBUI_REPO}:${IMAGE_TAG}"
docker push "${LITELLM_REPO}:${IMAGE_TAG}"
docker push "${CHROMADB_REPO}:${IMAGE_TAG}"
docker push "${OLLAMA_REPO}:${IMAGE_TAG}"

print_success "Images pushed to ECR"

# ------------------------------------------------------------------------------
# STEP 5: FORCE ECS REDEPLOY
# ------------------------------------------------------------------------------

print_header "STEP 5: Refreshing ECS Service"

ECS_CLUSTER=$(terraform -chdir="$TF_DIR" output -raw ecs_cluster_name)
ECS_SERVICE=$(terraform -chdir="$TF_DIR" output -raw ecs_service_name)

aws ecs update-service \
    --cluster "$ECS_CLUSTER" \
    --service "$ECS_SERVICE" \
    --force-new-deployment \
    --region "$REGION" >/dev/null

print_success "ECS service refreshed"

print_header "DEPLOYMENT COMPLETE"
print_info "Service URLs:"
terraform -chdir="$TF_DIR" output -json service_urls
