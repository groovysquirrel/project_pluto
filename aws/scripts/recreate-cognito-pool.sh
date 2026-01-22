#!/bin/bash
# ==============================================================================
# RECREATE COGNITO USER POOL
# ==============================================================================
# This script handles the complete recreation of a Cognito User Pool with
# custom required attributes. Terraform cannot set standard attributes as
# required, so this script:
#   1. Destroys the existing pool (and its domain)
#   2. Removes it from Terraform state
#   3. Creates a new pool via AWS CLI with required attributes
#   4. Imports it back into Terraform
#
# Usage: ./recreate-cognito-pool.sh [--auto-approve]
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWS_DIR="$(dirname "$SCRIPT_DIR")"
TF_DIR="$AWS_DIR/terraform"
ENV_FILE="$AWS_DIR/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# HELPER FUNCTIONS
# ------------------------------------------------------------------------------

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"

    if [[ "$AUTO_APPROVE" == "true" ]]; then
        return 0
    fi

    if [[ "$default" == "y" ]]; then
        read -p "$prompt [Y/n]: " response
        response=${response:-y}
    else
        read -p "$prompt [y/N]: " response
        response=${response:-n}
    fi

    [[ "$response" =~ ^[Yy]$ ]]
}

# ------------------------------------------------------------------------------
# LOAD CONFIGURATION
# ------------------------------------------------------------------------------

load_config() {
    log_info "Loading configuration..."

    if [[ ! -f "$ENV_FILE" ]]; then
        log_error "Environment file not found: $ENV_FILE"
        exit 1
    fi

    # Load .env file
    set -a
    source "$ENV_FILE"
    set +a

    # Get values from env
    PROJECT_NAME="${TF_VAR_project_name:-pluto}"
    POOL_NAME="${PROJECT_NAME}-users"
    AWS_REGION="${AWS_REGION:-$(aws configure get region)}"

    if [[ -z "$AWS_REGION" ]]; then
        log_error "AWS_REGION not set and not found in AWS config"
        exit 1
    fi

    log_success "Configuration loaded"
    echo "  Project: $PROJECT_NAME"
    echo "  Pool Name: $POOL_NAME"
    echo "  Region: $AWS_REGION"
}

# ------------------------------------------------------------------------------
# GET CURRENT POOL INFO
# ------------------------------------------------------------------------------

get_current_pool() {
    log_info "Checking for existing Cognito User Pool..."

    CURRENT_POOL_ID=$(aws cognito-idp list-user-pools \
        --max-results 20 \
        --region "$AWS_REGION" \
        --query "UserPools[?Name=='$POOL_NAME'].Id" \
        --output text 2>/dev/null || echo "")

    if [[ -n "$CURRENT_POOL_ID" && "$CURRENT_POOL_ID" != "None" ]]; then
        log_info "Found existing pool: $CURRENT_POOL_ID"

        # Get pool details
        POOL_INFO=$(aws cognito-idp describe-user-pool \
            --user-pool-id "$CURRENT_POOL_ID" \
            --region "$AWS_REGION" \
            --query "UserPool.{Domain:Domain,CustomDomain:CustomDomain}" \
            --output json 2>/dev/null || echo "{}")

        CURRENT_DOMAIN=$(echo "$POOL_INFO" | grep -o '"Domain": *"[^"]*"' | cut -d'"' -f4 || echo "")
        CURRENT_CUSTOM_DOMAIN=$(echo "$POOL_INFO" | grep -o '"CustomDomain": *"[^"]*"' | cut -d'"' -f4 || echo "")

        # Get current required attributes
        CURRENT_REQUIRED=$(aws cognito-idp describe-user-pool \
            --user-pool-id "$CURRENT_POOL_ID" \
            --region "$AWS_REGION" \
            --query "UserPool.SchemaAttributes[?Required==\`true\`].Name" \
            --output text 2>/dev/null | tr '\t' ' ' || echo "")

        echo "  Domain: ${CURRENT_DOMAIN:-none}"
        echo "  Custom Domain: ${CURRENT_CUSTOM_DOMAIN:-none}"
        echo "  Current Required Attributes: $CURRENT_REQUIRED"

        POOL_EXISTS=true
    else
        log_info "No existing pool found with name: $POOL_NAME"
        POOL_EXISTS=false
    fi
}

# ------------------------------------------------------------------------------
# SELECT REQUIRED ATTRIBUTES
# ------------------------------------------------------------------------------

select_required_attributes() {
    echo ""
    log_info "Select required attributes for the new pool"
    echo ""
    echo "Available standard attributes that can be set as required:"
    echo "  1. name        - User's full name (recommended for display)"
    echo "  2. email       - Email address (always recommended)"
    echo "  3. phone_number"
    echo "  4. given_name"
    echo "  5. family_name"
    echo "  6. nickname"
    echo "  7. preferred_username"
    echo "  8. profile"
    echo "  9. picture"
    echo " 10. website"
    echo " 11. gender"
    echo " 12. birthdate"
    echo " 13. zoneinfo"
    echo " 14. locale"
    echo " 15. address"
    echo ""
    echo -e "${YELLOW}NOTE: Once set, required attributes CANNOT be changed without recreating the pool.${NC}"
    echo -e "${YELLOW}      Only select attributes you can populate from your identity provider.${NC}"
    echo ""

    # Default selection
    DEFAULT_ATTRS="name,email"

    read -p "Enter comma-separated attribute names [default: $DEFAULT_ATTRS]: " SELECTED_ATTRS
    SELECTED_ATTRS="${SELECTED_ATTRS:-$DEFAULT_ATTRS}"

    # Clean up input
    SELECTED_ATTRS=$(echo "$SELECTED_ATTRS" | tr -d ' ')

    # Validate attributes
    VALID_ATTRS="name email phone_number given_name family_name nickname preferred_username profile picture website gender birthdate zoneinfo locale address"

    IFS=',' read -ra ATTR_ARRAY <<< "$SELECTED_ATTRS"
    SCHEMA_ARGS=""
    SCHEMA_BLOCKS=""

    for attr in "${ATTR_ARRAY[@]}"; do
        if [[ ! " $VALID_ATTRS " =~ " $attr " ]]; then
            log_error "Invalid attribute: $attr"
            exit 1
        fi

        # Build AWS CLI schema argument
        if [[ -n "$SCHEMA_ARGS" ]]; then
            SCHEMA_ARGS="$SCHEMA_ARGS "
        fi
        SCHEMA_ARGS="${SCHEMA_ARGS}Name=$attr,AttributeDataType=String,Required=true,Mutable=true"
    done

    echo ""
    log_info "Selected required attributes: $SELECTED_ATTRS"

    if ! confirm "Proceed with these attributes?"; then
        log_error "Aborted by user"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# CLEANUP RELATED AWS RESOURCES
# ------------------------------------------------------------------------------

cleanup_related_resources() {
    log_info "Cleaning up related AWS resources..."

    # Get the Lambda function ARN for presignup
    LAMBDA_FUNCTION_NAME="${PROJECT_NAME}-cognito-presignup"

    # Remove Lambda permission (it references the old pool ARN)
    log_info "Removing Lambda permission for old pool..."
    aws lambda remove-permission \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --statement-id "AllowCognitoInvoke" \
        --region "$AWS_REGION" 2>/dev/null || log_info "  (no existing permission or already removed)"

    # Delete Route53 auth record if it exists (points to old CloudFront)
    COGNITO_CUSTOM_DOMAIN="${TF_VAR_cognito_custom_domain:-}"
    if [[ -n "$COGNITO_CUSTOM_DOMAIN" ]]; then
        log_info "Checking for stale Route53 auth record..."
        HOSTED_ZONE_NAME="${TF_VAR_hosted_zone_name:-}"
        if [[ -n "$HOSTED_ZONE_NAME" ]]; then
            ZONE_ID=$(aws route53 list-hosted-zones-by-name \
                --dns-name "$HOSTED_ZONE_NAME" \
                --query "HostedZones[?Name=='${HOSTED_ZONE_NAME}.'] | [0].Id" \
                --output text 2>/dev/null | sed 's|/hostedzone/||')

            if [[ -n "$ZONE_ID" && "$ZONE_ID" != "None" ]]; then
                # Get the current record
                AUTH_RECORD=$(aws route53 list-resource-record-sets \
                    --hosted-zone-id "$ZONE_ID" \
                    --query "ResourceRecordSets[?Name=='${COGNITO_CUSTOM_DOMAIN}.'][0]" \
                    --output json 2>/dev/null || echo "{}")

                if [[ "$AUTH_RECORD" != "{}" && "$AUTH_RECORD" != "null" ]]; then
                    log_info "Deleting stale auth Route53 record..."
                    # Extract the alias target for deletion
                    ALIAS_DNS=$(echo "$AUTH_RECORD" | grep -o '"DNSName": *"[^"]*"' | cut -d'"' -f4 || echo "")
                    if [[ -n "$ALIAS_DNS" ]]; then
                        aws route53 change-resource-record-sets \
                            --hosted-zone-id "$ZONE_ID" \
                            --change-batch "{
                                \"Changes\": [{
                                    \"Action\": \"DELETE\",
                                    \"ResourceRecordSet\": $AUTH_RECORD
                                }]
                            }" 2>/dev/null || log_info "  (could not delete - may be managed by Terraform)"
                    fi
                fi
            fi
        fi
    fi

    log_success "Related resources cleaned up"
}

# ------------------------------------------------------------------------------
# DESTROY EXISTING POOL
# ------------------------------------------------------------------------------

destroy_existing_pool() {
    if [[ "$POOL_EXISTS" != "true" ]]; then
        log_info "No existing pool to destroy"
        return
    fi

    echo ""
    log_warn "This will DESTROY the existing Cognito User Pool!"
    log_warn "All users in the pool will be DELETED!"
    echo ""

    if ! confirm "Are you sure you want to destroy pool $CURRENT_POOL_ID?"; then
        log_error "Aborted by user"
        exit 1
    fi

    # Clean up related resources first
    cleanup_related_resources

    # Delete domain first (required before pool deletion)
    if [[ -n "$CURRENT_DOMAIN" && "$CURRENT_DOMAIN" != "null" ]]; then
        log_info "Deleting Cognito domain: $CURRENT_DOMAIN"
        aws cognito-idp delete-user-pool-domain \
            --domain "$CURRENT_DOMAIN" \
            --user-pool-id "$CURRENT_POOL_ID" \
            --region "$AWS_REGION" 2>/dev/null || true
        log_success "Domain deleted"
    fi

    # Delete the user pool
    log_info "Deleting User Pool: $CURRENT_POOL_ID"
    aws cognito-idp delete-user-pool \
        --user-pool-id "$CURRENT_POOL_ID" \
        --region "$AWS_REGION"
    log_success "User Pool deleted"
}

# ------------------------------------------------------------------------------
# UPDATE TERRAFORM STATE
# ------------------------------------------------------------------------------

update_terraform_state() {
    log_info "Updating Terraform state..."

    cd "$TF_DIR"

    # Export env vars for Terraform
    export $(grep -v '^#' "$ENV_FILE" | xargs)

    # Remove old resources from state (ignore errors if not present)
    # These will be recreated by Terraform on next apply
    local resources=(
        "aws_cognito_user_pool.pluto"
        "aws_cognito_user_pool_client.alb"
        "aws_cognito_user_pool_domain.pluto"
        "aws_lambda_permission.cognito_presignup"
        "aws_route53_record.auth"
        "aws_secretsmanager_secret_version.cognito_client_secret"
    )

    for resource in "${resources[@]}"; do
        log_info "Removing $resource from state..."
        terraform state rm "$resource" 2>/dev/null || true
    done

    log_success "Terraform state cleaned"
}

# ------------------------------------------------------------------------------
# CREATE NEW POOL
# ------------------------------------------------------------------------------

create_new_pool() {
    log_info "Creating new Cognito User Pool with required attributes: $SELECTED_ATTRS"

    # Build the schema arguments array
    IFS=',' read -ra ATTR_ARRAY <<< "$SELECTED_ATTRS"
    SCHEMA_PARAMS=""
    for attr in "${ATTR_ARRAY[@]}"; do
        SCHEMA_PARAMS="$SCHEMA_PARAMS Name=$attr,AttributeDataType=String,Required=true,Mutable=true"
    done

    # Check if presignup Lambda exists
    LAMBDA_FUNCTION_NAME="${PROJECT_NAME}-cognito-presignup"
    LAMBDA_ARN=$(aws lambda get-function \
        --function-name "$LAMBDA_FUNCTION_NAME" \
        --region "$AWS_REGION" \
        --query "Configuration.FunctionArn" \
        --output text 2>/dev/null || echo "")

    # Build lambda-config if Lambda exists
    LAMBDA_CONFIG=""
    if [[ -n "$LAMBDA_ARN" && "$LAMBDA_ARN" != "None" ]]; then
        log_info "Found presignup Lambda: $LAMBDA_ARN"
        LAMBDA_CONFIG="--lambda-config PreSignUp=$LAMBDA_ARN"
    else
        log_warn "Presignup Lambda not found - pool will be created without email domain restriction"
    fi

    NEW_POOL_ID=$(aws cognito-idp create-user-pool \
        --pool-name "$POOL_NAME" \
        --schema $SCHEMA_PARAMS \
        --username-attributes email \
        --auto-verified-attributes email \
        --policies '{"PasswordPolicy":{"MinimumLength":8,"RequireUppercase":true,"RequireLowercase":true,"RequireNumbers":true,"RequireSymbols":false}}' \
        --admin-create-user-config '{"AllowAdminCreateUserOnly":false}' \
        --account-recovery-setting '{"RecoveryMechanisms":[{"Name":"verified_email","Priority":1}]}' \
        $LAMBDA_CONFIG \
        --region "$AWS_REGION" \
        --user-pool-tags Name="${PROJECT_NAME}-user-pool" \
        --query "UserPool.Id" \
        --output text)

    if [[ -z "$NEW_POOL_ID" ]]; then
        log_error "Failed to create new User Pool"
        exit 1
    fi

    log_success "Created new User Pool: $NEW_POOL_ID"

    # Add Lambda permission for the new pool
    if [[ -n "$LAMBDA_ARN" && "$LAMBDA_ARN" != "None" ]]; then
        log_info "Adding Lambda permission for new pool..."
        NEW_POOL_ARN="arn:aws:cognito-idp:${AWS_REGION}:$(aws sts get-caller-identity --query Account --output text):userpool/${NEW_POOL_ID}"
        aws lambda add-permission \
            --function-name "$LAMBDA_FUNCTION_NAME" \
            --statement-id "AllowCognitoInvoke" \
            --action "lambda:InvokeFunction" \
            --principal "cognito-idp.amazonaws.com" \
            --source-arn "$NEW_POOL_ARN" \
            --region "$AWS_REGION" 2>/dev/null || log_warn "  (permission may already exist)"
        log_success "Lambda permission added"
    fi
}

# ------------------------------------------------------------------------------
# UPDATE TERRAFORM CONFIG
# ------------------------------------------------------------------------------

update_terraform_config() {
    log_info "Updating Terraform configuration (cognito.tf)..."

    # Generate schema blocks for cognito.tf
    IFS=',' read -ra ATTR_ARRAY <<< "$SELECTED_ATTRS"

    SCHEMA_BLOCKS=""
    for attr in "${ATTR_ARRAY[@]}"; do
        SCHEMA_BLOCKS="${SCHEMA_BLOCKS}
  schema {
    name                = \"$attr\"
    attribute_data_type = \"String\"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = \"0\"
      max_length = \"2048\"
    }
  }
"
    done

    # Create the replacement content
    NEW_SCHEMA_SECTION="  # Schema: Required attributes (set at pool creation via AWS CLI)
  # Terraform cannot set standard attributes as required, so pool was created
  # externally and imported. These schema blocks must match the imported pool.
  # Required: $SELECTED_ATTRS
$SCHEMA_BLOCKS
  # Lambda triggers for email domain restriction"

    # Backup original file
    cp "$TF_DIR/cognito.tf" "$TF_DIR/cognito.tf.backup"

    # Use sed to replace the schema section
    # This is a simplified approach - for complex cases, manual editing may be needed

    log_warn "Please verify cognito.tf schema blocks match: $SELECTED_ATTRS"
    log_info "A backup was saved to cognito.tf.backup"

    echo ""
    echo "Expected schema blocks in cognito.tf:"
    echo "----------------------------------------"
    echo "$SCHEMA_BLOCKS"
    echo "----------------------------------------"
}

# ------------------------------------------------------------------------------
# IMPORT INTO TERRAFORM
# ------------------------------------------------------------------------------

import_to_terraform() {
    log_info "Importing new User Pool into Terraform..."

    cd "$TF_DIR"

    # Export env vars for Terraform
    export $(grep -v '^#' "$ENV_FILE" | xargs)

    terraform import aws_cognito_user_pool.pluto "$NEW_POOL_ID"

    log_success "User Pool imported into Terraform"
}

# ------------------------------------------------------------------------------
# VERIFY AND NEXT STEPS
# ------------------------------------------------------------------------------

show_next_steps() {
    echo ""
    echo "=============================================================================="
    log_success "Cognito User Pool recreated successfully!"
    echo "=============================================================================="
    echo ""
    echo "New Pool ID: $NEW_POOL_ID"
    echo "Required Attributes: $SELECTED_ATTRS"
    echo ""
    echo "Next steps:"
    echo "  1. Verify cognito.tf has the correct schema blocks for: $SELECTED_ATTRS"
    echo "  2. Run: ./pluto.sh deploy aws"
    echo "     This will create the domain, client, and other dependent resources."
    echo ""
    echo "If you need to modify the schema blocks manually, edit:"
    echo "  $TF_DIR/cognito.tf"
    echo ""
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

main() {
    echo "=============================================================================="
    echo "  COGNITO USER POOL RECREATION SCRIPT"
    echo "=============================================================================="
    echo ""

    # Parse arguments
    AUTO_APPROVE=false
    for arg in "$@"; do
        case $arg in
            --auto-approve)
                AUTO_APPROVE=true
                ;;
        esac
    done

    load_config
    get_current_pool
    select_required_attributes
    destroy_existing_pool
    update_terraform_state
    create_new_pool
    update_terraform_config
    import_to_terraform
    show_next_steps
}

main "$@"
