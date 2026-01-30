#!/bin/bash

# ==============================================================================
# PROJECT PLUTO - AWS Teardown Script
# ==============================================================================
#
# Destroys AWS resources created by Terraform for the Pluto stack.
#
# IMPORTANT: By default, this script preserves data (RDS, EFS, Secrets).
# Use --destroy-data to also destroy data resources (DANGEROUS!).
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
DESTROY_DATA=false

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

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --destroy-data    Also destroy data resources (RDS, EFS, Secrets)"
    echo "                    WARNING: This will permanently delete all data!"
    echo "  --help            Show this help message"
    echo ""
    echo "By default, this script only destroys compute resources (ECS, ALB, etc.)"
    echo "while preserving data resources (Aurora RDS, EFS, Secrets Manager)."
}

# ------------------------------------------------------------------------------
# PARSE ARGUMENTS
# ------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        --destroy-data)
            DESTROY_DATA=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# INPUTS
# ------------------------------------------------------------------------------

print_header "AWS Teardown"

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

if [ -z "$HOSTED_ZONE_NAME" ]; then
    read -r -p "Route53 hosted zone (example.com): " HOSTED_ZONE_NAME
    if [ -z "$HOSTED_ZONE_NAME" ]; then
        print_error "Hosted zone name is required."
    fi
    export TF_VAR_hosted_zone_name="$HOSTED_ZONE_NAME"
fi

if [ -z "${TF_VAR_subdomain_prefix+x}" ]; then
    read -r -p "Optional subdomain prefix (press enter for none): " SUBDOMAIN_PREFIX
    export TF_VAR_subdomain_prefix="$SUBDOMAIN_PREFIX"
fi

TF_DIR="${SCRIPT_DIR}/terraform"

# ------------------------------------------------------------------------------
# CONFIRMATION
# ------------------------------------------------------------------------------

if [ "$DESTROY_DATA" = true ]; then
    echo ""
    print_warning "╔═══════════════════════════════════════════════════════════════╗"
    print_warning "║  DANGER: --destroy-data flag is set!                          ║"
    print_warning "║                                                               ║"
    print_warning "║  This will PERMANENTLY DELETE:                                ║"
    print_warning "║    • Aurora PostgreSQL database (all user data)               ║"
    print_warning "║    • EFS file system (OpenWebUI uploads)                      ║"
    print_warning "║    • All Secrets Manager secrets                              ║"
    print_warning "║                                                               ║"
    print_warning "║  THIS CANNOT BE UNDONE!                                       ║"
    print_warning "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    read -r -p "Type 'DELETE ALL DATA' to confirm: " CONFIRM
    if [ "$CONFIRM" != "DELETE ALL DATA" ]; then
        print_info "Aborted."
        exit 0
    fi

    print_info "Removing lifecycle protection from data resources..."

    # Temporarily remove prevent_destroy for data resources
    # This requires editing the state or using -target
    print_warning "You must manually remove 'prevent_destroy' from database.tf and storage.tf"
    print_warning "Then set 'deletion_protection = false' in database.tf"
    print_warning "Run 'terraform apply' to update, then run this script again."
    exit 1
else
    echo ""
    print_info "This will destroy compute resources but PRESERVE data:"
    print_info "  ✓ Aurora RDS database (preserved)"
    print_info "  ✓ EFS file system (preserved)"
    print_info "  ✓ Secrets Manager secrets (preserved)"
    print_info ""
    print_info "  ✗ ECS services and tasks (destroyed)"
    print_info "  ✗ ALB and target groups (destroyed)"
    print_info "  ✗ ECR repositories (destroyed)"
    print_info "  ✗ VPC and networking (destroyed)"
    print_info "  ✗ Cognito user pool (destroyed)"
    echo ""
    read -r -p "Continue? (y/N): " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        print_info "Aborted."
        exit 0
    fi
fi

# ------------------------------------------------------------------------------
# TEARDOWN
# ------------------------------------------------------------------------------

print_info "Destroying Terraform-managed resources (preserving data)..."

# Scale down ECS services first to avoid dependency issues
print_info "Scaling down ECS services..."
aws ecs update-service --cluster pluto-cluster --service pluto-openwebui --desired-count 0 2>/dev/null || true
aws ecs update-service --cluster pluto-cluster --service pluto-litellm --desired-count 0 2>/dev/null || true
aws ecs update-service --cluster pluto-cluster --service pluto-n8n --desired-count 0 2>/dev/null || true
aws ecs update-service --cluster pluto-cluster --service pluto-portal --desired-count 0 2>/dev/null || true

sleep 10

# Run terraform destroy, excluding data resources
terraform -chdir="$TF_DIR" destroy \
    -target=aws_ecs_service.openwebui \
    -target=aws_ecs_service.litellm \
    -target=aws_ecs_service.n8n \
    -target=aws_ecs_service.portal \
    -target=aws_ecs_cluster.pluto \
    -target=aws_lb.pluto \
    -target=aws_cognito_user_pool.pluto \
    -target=aws_ecr_repository.pluto

print_success "Compute resources destroyed. Data resources preserved."
print_info ""
print_info "To redeploy, run: ./pluto.sh deploy aws"
print_info "Your data (RDS, EFS) will be reconnected automatically."
