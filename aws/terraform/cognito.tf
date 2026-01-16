# -----------------------------------------------------------------------------
# COGNITO USER POOL - Authentication for all services
# -----------------------------------------------------------------------------

resource "aws_cognito_user_pool" "pluto" {
  name = "${var.project_name}-users"

  # Password policy
  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }

  # Allow users to sign up themselves (can be disabled for invite-only)
  admin_create_user_config {
    allow_admin_create_user_only = var.cognito_admin_only_signup
  }

  # Use email as the primary username
  username_attributes = ["email"]
  
  auto_verified_attributes = ["email"]

  # Email configuration (uses Cognito default, can upgrade to SES)
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # Account recovery via email
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Schema attributes
  schema {
    name                     = "email"
    attribute_data_type      = "String"
    required                 = true
    mutable                  = true
    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }

  tags = {
    Name = "${var.project_name}-user-pool"
  }
}

# -----------------------------------------------------------------------------
# COGNITO USER POOL DOMAIN
# -----------------------------------------------------------------------------

resource "aws_cognito_user_pool_domain" "pluto" {
  domain          = var.cognito_custom_domain != "" ? "auth.${local.domain_root}" : "${var.project_name}-${random_string.cognito_domain_suffix.result}"
  user_pool_id    = aws_cognito_user_pool.pluto.id
  certificate_arn = var.cognito_custom_domain != "" ? aws_acm_certificate_validation.pluto.certificate_arn : null
}

resource "random_string" "cognito_domain_suffix" {
  length  = 8
  special = false
  upper   = false
}

# -----------------------------------------------------------------------------
# COGNITO USER POOL CLIENT - For ALB Authentication
# -----------------------------------------------------------------------------

resource "aws_cognito_user_pool_client" "alb" {
  name         = "${var.project_name}-alb-client"
  user_pool_id = aws_cognito_user_pool.pluto.id

  # ALB requires a client secret
  generate_secret = true

  # OAuth configuration for ALB
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  # Callback URLs for each service
  callback_urls = [
    "https://${local.service_hosts.openwebui}/oauth2/idpresponse",
    "https://${local.service_hosts.litellm}/oauth2/idpresponse",
    "https://${local.service_hosts.n8n}/oauth2/idpresponse",
    "https://${local.service_hosts.portal}/oauth2/idpresponse",
    "https://${local.domain_root}/oauth2/idpresponse",
  ]

  logout_urls = [
    "https://${local.service_hosts.portal}",
    "https://${local.domain_root}",
  ]

  supported_identity_providers = ["COGNITO"]

  # Token validity
  access_token_validity  = 1   # hours
  id_token_validity      = 1   # hours
  refresh_token_validity = 30  # days

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Prevent token revocation on logout (simpler for ALB auth)
  enable_token_revocation = true

  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH",
  ]
}

# -----------------------------------------------------------------------------
# COGNITO OUTPUTS (for reference)
# -----------------------------------------------------------------------------

output "cognito_user_pool_id" {
  value       = aws_cognito_user_pool.pluto.id
  description = "Cognito User Pool ID"
}

output "cognito_user_pool_endpoint" {
  value       = aws_cognito_user_pool.pluto.endpoint
  description = "Cognito User Pool endpoint"
}

output "cognito_domain" {
  value       = aws_cognito_user_pool_domain.pluto.domain
  description = "Cognito hosted UI domain"
}

output "cognito_login_url" {
  value       = "https://${aws_cognito_user_pool_domain.pluto.domain}.auth.${data.aws_region.current.name}.amazoncognito.com/login"
  description = "Cognito hosted UI login URL"
}