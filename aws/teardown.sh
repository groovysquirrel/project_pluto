#!/bin/bash

# ==============================================================================
# PROJECT PLUTO - AWS Teardown Script
# ==============================================================================
#
# Destroys AWS resources created by Terraform for the Pluto stack.
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

print_error() {
    echo -e "${RED}✗ ERROR: $1${NC}"
    exit 1
}

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

print_info "Destroying Terraform-managed resources"

# Run terraform destroy
# Assuming env vars are exported (TF_VAR_...)
terraform -chdir="$TF_DIR" destroy

print_success "Teardown complete"
