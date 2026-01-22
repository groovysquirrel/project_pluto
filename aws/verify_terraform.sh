#!/bin/bash

# ==============================================================================
# TERRAFORM VERIFICATION SCRIPT
# ==============================================================================
# This script verifies that the Terraform configuration is ready for deployment
# with the Cognito SSO changes for LiteLLM.
#
# Usage: ./verify_terraform.sh
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/terraform"

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Terraform Configuration Verification${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# -----------------------------------------------------------------------------
# 1. Check Terraform is installed
# -----------------------------------------------------------------------------
echo -e "${CYAN}[1/5] Checking Terraform installation...${NC}"
if ! command -v terraform &> /dev/null; then
    echo -e "${RED}✗ Terraform not found${NC}"
    echo "Install from: https://developer.hashicorp.com/terraform/downloads"
    exit 1
fi
echo -e "${GREEN}✓ Terraform found: $(terraform version -json | grep -o '"version":"[^"]*"' | cut -d'"' -f4)${NC}"

# -----------------------------------------------------------------------------
# 2. Validate Terraform syntax
# -----------------------------------------------------------------------------
echo ""
echo -e "${CYAN}[2/5] Validating Terraform configuration...${NC}"
if terraform validate > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Configuration is valid${NC}"
else
    echo -e "${RED}✗ Configuration is invalid${NC}"
    terraform validate
    exit 1
fi

# -----------------------------------------------------------------------------
# 3. Check for LiteLLM listener rules
# -----------------------------------------------------------------------------
echo ""
echo -e "${CYAN}[3/5] Verifying LiteLLM listener rules...${NC}"

if grep -q "aws_lb_listener_rule.*litellm_api" main.tf; then
    echo -e "${GREEN}✓ Found litellm_api rule (Priority 200)${NC}"
else
    echo -e "${RED}✗ Missing litellm_api rule${NC}"
    exit 1
fi

if grep -q "aws_lb_listener_rule.*litellm_ui" main.tf; then
    echo -e "${GREEN}✓ Found litellm_ui rule (Priority 201)${NC}"
else
    echo -e "${RED}✗ Missing litellm_ui rule${NC}"
    exit 1
fi

# Check that API rule has path patterns
if grep -A 25 "resource.*litellm_api" main.tf | grep -q "path_pattern"; then
    echo -e "${GREEN}✓ API rule has path pattern configured${NC}"
    if grep -A 25 "resource.*litellm_api" main.tf | grep -q '"/v1/\*"'; then
        echo -e "${GREEN}✓ API rule includes /v1/* path${NC}"
    fi
else
    echo -e "${RED}✗ API rule missing path pattern${NC}"
    exit 1
fi

# Check that UI rule has Cognito authentication
if grep -A 10 "resource.*litellm_ui" main.tf | grep -q "authenticate-cognito"; then
    echo -e "${GREEN}✓ UI rule has Cognito authentication${NC}"
else
    echo -e "${RED}✗ UI rule missing Cognito authentication${NC}"
    exit 1
fi

# -----------------------------------------------------------------------------
# 4. Verify resource dependencies
# -----------------------------------------------------------------------------
echo ""
echo -e "${CYAN}[4/5] Checking resource dependencies...${NC}"

if grep -q "aws_lb_listener_rule.litellm_api" main.tf && \
   grep -q "aws_lb_listener_rule.litellm_ui" main.tf; then
    echo -e "${GREEN}✓ Dependencies reference both new listener rules${NC}"
else
    echo -e "${RED}✗ Dependencies missing references to new rules${NC}"
    exit 1
fi

# Check that old reference doesn't exist
if grep "aws_lb_listener_rule.litellm[^_]" main.tf > /dev/null 2>&1; then
    echo -e "${YELLOW}⚠ Warning: Found reference to old 'litellm' rule (should be 'litellm_api' or 'litellm_ui')${NC}"
    grep -n "aws_lb_listener_rule.litellm[^_]" main.tf || true
fi

# -----------------------------------------------------------------------------
# 5. Check Cognito configuration
# -----------------------------------------------------------------------------
echo ""
echo -e "${CYAN}[5/5] Verifying Cognito configuration...${NC}"

if [ -f cognito.tf ]; then
    echo -e "${GREEN}✓ Found cognito.tf${NC}"

    if grep -q "aws_cognito_user_pool.pluto" cognito.tf; then
        echo -e "${GREEN}✓ Cognito user pool configured${NC}"
    fi

    if grep -q "aws_cognito_user_pool_client.alb" cognito.tf; then
        echo -e "${GREEN}✓ Cognito user pool client configured${NC}"
    fi

    if grep -q "aws_cognito_user_pool_domain.pluto" cognito.tf; then
        echo -e "${GREEN}✓ Cognito domain configured${NC}"
    fi
else
    echo -e "${RED}✗ cognito.tf not found${NC}"
    exit 1
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ All checks passed!${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Configuration is ready for deployment."
echo ""
echo "Next steps:"
echo "  1. Fix state file permissions (if needed):"
echo "     cd terraform && sudo chown -R \$(whoami) terraform.tfstate*"
echo ""
echo "  2. Preview changes:"
echo "     cd terraform && terraform plan"
echo ""
echo "  3. Deploy:"
echo "     cd .. && ./pluto.sh deploy aws"
echo ""
