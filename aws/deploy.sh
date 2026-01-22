#!/bin/bash

# ==============================================================================
# PROJECT PLUTO - AWS Deployment Script
# ==============================================================================
#
# Deploys the AWS stack with Terraform and pushes images to ECR.
#
# USAGE:
#   ./deploy.sh [OPTIONS]
#
# OPTIONS:
#   --skip-images    Skip Docker image build/push (faster for infra-only changes)
#   --skip-terraform Skip Terraform apply (redeploy images only)
#   --help           Show this help message
#
# ENVIRONMENT VARIABLES:
#   COGNITO_REQUIRED_ATTRS  Comma-separated list of required Cognito attributes
#                           Default: "name,email"
#                           Only used for fresh installs (new user pools)
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
TF_DIR="${SCRIPT_DIR}/terraform"

# Default options
SKIP_IMAGES=false
SKIP_TERRAFORM=false

# ------------------------------------------------------------------------------
# PARSE ARGUMENTS
# ------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-images)
            SKIP_IMAGES=true
            shift
            ;;
        --skip-terraform)
            SKIP_TERRAFORM=true
            shift
            ;;
        --help)
            head -25 "$0" | tail -20
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

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

if [ "$SKIP_IMAGES" = false ]; then
    if ! command -v docker &> /dev/null; then
        print_error "Docker not found. Install Docker Desktop and try again."
    fi
    print_success "Docker is installed"

    if ! docker info &> /dev/null; then
        print_error "Docker daemon is not running. Start Docker Desktop and try again."
    fi
    print_success "Docker is running"

    if ! command -v crane &> /dev/null; then
        print_error "crane not found. Install it with: brew install crane"
    fi
    print_success "crane is installed"
else
    print_info "Skipping Docker/crane check (--skip-images)"
fi

# ------------------------------------------------------------------------------
# STEP 2: LOAD CONFIGURATION
# ------------------------------------------------------------------------------

print_header "STEP 2: Loading Configuration"

# Load .env if it exists
if [ -f "${SCRIPT_DIR}/.env" ]; then
    print_info "Loading variables from ${SCRIPT_DIR}/.env"
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
fi

# Set defaults from env or prompt
HOSTED_ZONE_NAME="${TF_VAR_hosted_zone_name:-}"
SUBDOMAIN_PREFIX="${TF_VAR_subdomain_prefix:-}"
PROJECT_NAME="${TF_VAR_project_name:-pluto}"

if [ -z "$HOSTED_ZONE_NAME" ]; then
    read -r -p "Route53 hosted zone (example.com): " HOSTED_ZONE_NAME
    if [ -z "$HOSTED_ZONE_NAME" ]; then
        print_error "Hosted zone name is required."
    fi
    export TF_VAR_hosted_zone_name="$HOSTED_ZONE_NAME"
fi

# Only prompt if not set
if [ -z "${TF_VAR_subdomain_prefix+x}" ]; then
    read -r -p "Optional subdomain prefix (press enter for none): " SUBDOMAIN_PREFIX
    export TF_VAR_subdomain_prefix="$SUBDOMAIN_PREFIX"
fi

DOMAIN_ROOT="$HOSTED_ZONE_NAME"
if [ -n "$SUBDOMAIN_PREFIX" ]; then
    DOMAIN_ROOT="${SUBDOMAIN_PREFIX}.${HOSTED_ZONE_NAME}"
fi

print_info "Project: ${PROJECT_NAME}"
print_info "Domain: ${DOMAIN_ROOT}"

# Verify Route53 zone exists
ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name "$HOSTED_ZONE_NAME" \
    --query "HostedZones[?Name=='${HOSTED_ZONE_NAME}.'] | [0].Id" \
    --output text)

if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
    print_error "Hosted zone ${HOSTED_ZONE_NAME} not found in Route53. Please create it first."
fi
print_success "Route53 hosted zone verified"

# ------------------------------------------------------------------------------
# STEP 3: COGNITO USER POOL SETUP
# ------------------------------------------------------------------------------
# Terraform cannot set standard attributes (like name, email) as required.
# For fresh installs, we create the pool via AWS CLI and import it.

if [ "$SKIP_TERRAFORM" = false ]; then
    print_header "STEP 3: Cognito User Pool Setup"

    # Get AWS region
    AWS_REGION="${AWS_REGION:-$(aws configure get region)}"
    POOL_NAME="${PROJECT_NAME}-users"

    # Required attributes (configurable via env var)
    COGNITO_REQUIRED_ATTRS="${COGNITO_REQUIRED_ATTRS:-name,email}"

    # Initialize Terraform first (needed for state commands)
    print_info "Initializing Terraform..."
    terraform -chdir="$TF_DIR" init -upgrade > /dev/null

    # Check if pool exists in Terraform state
    POOL_IN_STATE=$(terraform -chdir="$TF_DIR" state list 2>/dev/null | grep "aws_cognito_user_pool.pluto" || echo "")

    if [ -n "$POOL_IN_STATE" ]; then
        print_success "Cognito User Pool already in Terraform state"
    else
        print_info "Cognito User Pool not in Terraform state"

        # Check if pool exists in AWS
        EXISTING_POOL_ID=$(aws cognito-idp list-user-pools \
            --max-results 20 \
            --region "$AWS_REGION" \
            --query "UserPools[?Name=='$POOL_NAME'].Id" \
            --output text 2>/dev/null || echo "")

        if [ -n "$EXISTING_POOL_ID" ] && [ "$EXISTING_POOL_ID" != "None" ]; then
            print_info "Found existing pool in AWS: $EXISTING_POOL_ID"
            print_info "Importing into Terraform..."
            terraform -chdir="$TF_DIR" import aws_cognito_user_pool.pluto "$EXISTING_POOL_ID"
            print_success "Pool imported"
        else
            print_info "No existing pool found. Creating new pool with required attributes: $COGNITO_REQUIRED_ATTRS"

            # Build schema arguments
            SCHEMA_PARAMS=""
            IFS=',' read -ra ATTR_ARRAY <<< "$COGNITO_REQUIRED_ATTRS"
            for attr in "${ATTR_ARRAY[@]}"; do
                SCHEMA_PARAMS="$SCHEMA_PARAMS Name=$attr,AttributeDataType=String,Required=true,Mutable=true"
            done

            # Create the pool via AWS CLI
            NEW_POOL_ID=$(aws cognito-idp create-user-pool \
                --pool-name "$POOL_NAME" \
                --schema $SCHEMA_PARAMS \
                --username-attributes email \
                --auto-verified-attributes email \
                --policies '{"PasswordPolicy":{"MinimumLength":8,"RequireUppercase":true,"RequireLowercase":true,"RequireNumbers":true,"RequireSymbols":false}}' \
                --admin-create-user-config '{"AllowAdminCreateUserOnly":false}' \
                --account-recovery-setting '{"RecoveryMechanisms":[{"Name":"verified_email","Priority":1}]}' \
                --region "$AWS_REGION" \
                --user-pool-tags Name="${PROJECT_NAME}-user-pool" \
                --query "UserPool.Id" \
                --output text)

            if [ -z "$NEW_POOL_ID" ]; then
                print_error "Failed to create Cognito User Pool"
            fi

            print_success "Created new pool: $NEW_POOL_ID"
            print_info "Importing into Terraform..."
            terraform -chdir="$TF_DIR" import aws_cognito_user_pool.pluto "$NEW_POOL_ID"
            print_success "Pool imported"

            echo ""
            print_warning "IMPORTANT: Ensure cognito.tf has schema blocks for: $COGNITO_REQUIRED_ATTRS"
            print_warning "If not, run: ./aws/scripts/recreate-cognito-pool.sh"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# STEP 4: TERRAFORM APPLY
# ------------------------------------------------------------------------------

if [ "$SKIP_TERRAFORM" = false ]; then
    print_header "STEP 4: Provisioning AWS Infrastructure"

    terraform -chdir="$TF_DIR" apply

    print_success "Terraform apply complete"
else
    print_header "STEP 3-4: Skipping Terraform (--skip-terraform)"
fi

# ------------------------------------------------------------------------------
# STEP 5: BUILD AND PUSH IMAGES
# ------------------------------------------------------------------------------

if [ "$SKIP_IMAGES" = false ]; then
    print_header "STEP 5: Building and Pushing Images to ECR"

    REGION=$(terraform -chdir="$TF_DIR" output -raw region)
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    IMAGE_TAG="${IMAGE_TAG:-latest}"

    print_info "Logging in to ECR (${REGION})"
    aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

    # Get ECR repository URLs
    ECR_URLS=$(terraform -chdir="$TF_DIR" output -json ecr_repository_urls)
    PORTAL_REPO=$(echo "$ECR_URLS" | python3 -c "import sys,json; print(json.load(sys.stdin)['portal'])")
    OPENWEBUI_REPO=$(echo "$ECR_URLS" | python3 -c "import sys,json; print(json.load(sys.stdin)['openwebui'])")
    LITELLM_REPO=$(echo "$ECR_URLS" | python3 -c "import sys,json; print(json.load(sys.stdin)['litellm'])")
    N8N_REPO=$(echo "$ECR_URLS" | python3 -c "import sys,json; print(json.load(sys.stdin)['n8n'])")

    # Generate env.js with Cognito configuration for Portal
    print_info "Generating portal configuration..."
    COGNITO_LOGIN_URL=$(terraform -chdir="$TF_DIR" output -raw cognito_login_url 2>/dev/null || echo "")
    COGNITO_CLIENT_ID=$(terraform -chdir="$TF_DIR" output -raw cognito_user_pool_client_id 2>/dev/null || echo "")
    COGNITO_DOMAIN=$(terraform -chdir="$TF_DIR" output -raw cognito_domain 2>/dev/null || echo "")
    PORTAL_URL="https://${DOMAIN_ROOT}"

    cat > "${REPO_ROOT}/common/portal/html/env.js" <<EOF
// Generated by deploy.sh - DO NOT EDIT
window.ENV_COGNITO_LOGIN_URL = "${COGNITO_LOGIN_URL}";
window.ENV_COGNITO_CLIENT_ID = "${COGNITO_CLIENT_ID}";
window.ENV_COGNITO_DOMAIN = "${COGNITO_DOMAIN}";
window.ENV_LOGOUT_REDIRECT_URI = "${PORTAL_URL}";
EOF

    # Build Portal
    print_info "Building Portal image..."
    docker build \
        --platform linux/amd64 \
        -t "${PORTAL_REPO}:${IMAGE_TAG}" \
        -f "${SCRIPT_DIR}/portal/Dockerfile" \
        "${REPO_ROOT}"

    # Copy public images to ECR using crane (handles multi-arch properly)
    print_info "Copying public images to ECR..."

    # Authenticate crane with ECR
    aws ecr get-login-password --region "$REGION" | crane auth login "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" --username AWS --password-stdin

    print_info "Copying OpenWebUI..."
    crane copy --platform linux/amd64 ghcr.io/open-webui/open-webui:0.7.2 "${OPENWEBUI_REPO}:${IMAGE_TAG}"

    print_info "Copying LiteLLM..."
    crane copy --platform linux/amd64 ghcr.io/berriai/litellm:main-latest "${LITELLM_REPO}:${IMAGE_TAG}"

    print_info "Copying n8n..."
    crane copy --platform linux/amd64 docker.n8n.io/n8nio/n8n:2.4.4 "${N8N_REPO}:${IMAGE_TAG}"

    # Push Portal (built locally)
    print_info "Pushing Portal image..."
    docker push "${PORTAL_REPO}:${IMAGE_TAG}"

    print_success "Images pushed to ECR"
else
    print_header "STEP 5: Skipping Images (--skip-images)"
    REGION=$(terraform -chdir="$TF_DIR" output -raw region)
fi

# ------------------------------------------------------------------------------
# STEP 6: REFRESH ECS SERVICES
# ------------------------------------------------------------------------------

print_header "STEP 6: Refreshing ECS Services"

ECS_CLUSTER=$(terraform -chdir="$TF_DIR" output -raw ecs_cluster_name)

for SERVICE in portal litellm openwebui n8n; do
    print_info "Refreshing ${SERVICE}..."
    if aws ecs update-service \
        --cluster "$ECS_CLUSTER" \
        --service "${PROJECT_NAME}-${SERVICE}" \
        --force-new-deployment \
        --region "$REGION" >/dev/null 2>&1; then
        print_success "${SERVICE} refreshed"
    else
        print_warning "${SERVICE} could not be refreshed (may not exist yet or still deploying)"
    fi
done

# ------------------------------------------------------------------------------
# COMPLETE
# ------------------------------------------------------------------------------

print_header "DEPLOYMENT COMPLETE"

echo ""
print_info "Service URLs:"
terraform -chdir="$TF_DIR" output -json service_urls | python3 -c "
import sys, json
urls = json.load(sys.stdin)
for name, url in urls.items():
    print(f'  {name}: {url}')
"

echo ""
print_info "Internal endpoints (for intra-cluster communication):"
terraform -chdir="$TF_DIR" output -json internal_service_endpoints | python3 -c "
import sys, json
urls = json.load(sys.stdin)
for name, url in urls.items():
    print(f'  {name}: {url}')
"

echo ""
print_success "Deployment finished! Services may take a few minutes to become healthy."
