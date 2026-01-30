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
    allow_admin_create_user_only = false
  }

  # Use email as the primary username
  username_attributes = ["email"]
  
  auto_verified_attributes = ["email"]

  # Email configuration (uses Cognito default)
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

  # Schema: Required attributes (set at pool creation via AWS CLI)
  # Terraform cannot set standard attributes as required, so pool was created
  # externally and imported. These schema blocks must match the imported pool.
  # Required: name, email
  schema {
    name                = "name"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = "0"
      max_length = "2048"
    }
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = "0"
      max_length = "2048"
    }
  }

  # Lambda triggers
  lambda_config {
    pre_sign_up       = aws_lambda_function.cognito_presignup.arn
    # Re-enabled: Using SQS-based provisioning for n8n user invitations
    post_confirmation = aws_lambda_function.cognito_postconfirm.arn
  }

  tags = {
    Name = "${var.project_name}-user-pool"
  }

  # Ensure Lambdas are created first
  depends_on = [
    aws_lambda_function.cognito_presignup,
    aws_lambda_function.cognito_postconfirm
  ]
}

# -----------------------------------------------------------------------------
# COGNITO USER POOL DOMAIN
# -----------------------------------------------------------------------------

resource "aws_cognito_user_pool_domain" "pluto" {
  domain          = var.cognito_custom_domain != "" ? var.cognito_custom_domain : "${var.project_name}-${random_string.cognito_domain_suffix.result}"
  user_pool_id    = aws_cognito_user_pool.pluto.id
  certificate_arn = var.cognito_custom_domain != "" ? aws_acm_certificate_validation.cognito[0].certificate_arn : null

  depends_on = [aws_route53_record.root]
}

resource "aws_route53_record" "auth" {
  zone_id         = data.aws_route53_zone.selected.zone_id
  name            = var.cognito_custom_domain
  type            = "A"
  allow_overwrite = true

  alias {
    evaluate_target_health = false
    name                   = aws_cognito_user_pool_domain.pluto.cloudfront_distribution_arn
    # This is the fixed CloudFront Zone ID for Cognito
    # See: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-properties-route53-aliastarget.html
    zone_id                = "Z2FDTNDATAQYW2"
  }
}

# -----------------------------------------------------------------------------
# GOOGLE IDENTITY PROVIDER (External IdP)
# -----------------------------------------------------------------------------

resource "aws_cognito_identity_provider" "google" {
  count = var.enable_google_oauth ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.pluto.id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    authorize_scopes              = "profile email openid"
    client_id                     = var.google_oauth_client_id
    client_secret                 = var.google_oauth_client_secret
    attributes_url                = "https://people.googleapis.com/v1/people/me?personFields="
    attributes_url_add_attributes = "true"
    authorize_url                 = "https://accounts.google.com/o/oauth2/v2/auth"
    oidc_issuer                   = "https://accounts.google.com"
    token_url                     = "https://www.googleapis.com/oauth2/v4/token"
    token_request_method          = "POST"
  }

  attribute_mapping = {
    email    = "email"
    name     = "name"
    username = "sub"
  }
}

# -----------------------------------------------------------------------------
# ACM CERTIFICATE (US-EAST-1) for Cognito
# -----------------------------------------------------------------------------

resource "aws_acm_certificate" "cognito" {
  provider          = aws.us_east_1
  domain_name       = var.cognito_custom_domain != "" ? var.cognito_custom_domain : "auth.example.com" # Fallback dummy if unused
  validation_method = "DNS"

  # Only create if we are actually using a custom domain
  count = var.cognito_custom_domain != "" ? 1 : 0

  tags = {
    Name = "${var.project_name}-cognito-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cognito_validation" {
  for_each = var.cognito_custom_domain != "" ? {
    for dvo in aws_acm_certificate.cognito[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id = data.aws_route53_zone.selected.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cognito" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cognito[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cognito_validation : record.fqdn]

  # Only create if using custom domain
  count = var.cognito_custom_domain != "" ? 1 : 0
  depends_on = [aws_route53_record.root]
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

  # OAuth configuration for ALB (code flow) and Portal (implicit flow)
  allowed_oauth_flows                  = ["code", "implicit"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  # Callback URLs for each service + generic
  # IMPORTANT: the /oauth2/idpresponse path is required by ALB for token exchange
  callback_urls = [
    # Root domain redirect for Portal implicit flow
    "https://${local.domain_root}/",
    # ALB Cognito authentication callbacks
    "https://${local.domain_root}/oauth2/idpresponse",
    # oauth2-proxy callback for Portal
    "https://${local.domain_root}/oauth2/callback",
    # oauth2-proxy callbacks for OpenWebUI, LiteLLM and n8n
    "https://${local.service_hosts.openwebui}/oauth2/callback",
    "https://${local.service_hosts.litellm}/oauth2/callback",
    "https://${local.service_hosts.n8n}/oauth2/callback",
    # LiteLLM native SSO callback
    "https://${local.service_hosts.litellm}/sso/callback"
  ]

  logout_urls = [
    "https://${local.domain_root}",
    "https://${local.service_hosts.openwebui}",
    "https://${local.service_hosts.litellm}"
  ]

  # Include Google if enabled (must match var.enable_google_oauth)
  supported_identity_providers = var.enable_google_oauth ? ["COGNITO", "Google"] : ["COGNITO"]

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
    "ALLOW_ADMIN_USER_PASSWORD_AUTH"
  ]
}

# -----------------------------------------------------------------------------
# COGNITO PRE-SIGNUP LAMBDA (Email Domain Restriction)
# -----------------------------------------------------------------------------

data "archive_file" "cognito_presignup" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/cognito_presignup"
  output_path = "${path.module}/../lambda/cognito_presignup.zip"
}

resource "aws_iam_role" "cognito_presignup" {
  name = "${var.project_name}-cognito-presignup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cognito_presignup_logs" {
  role       = aws_iam_role.cognito_presignup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "cognito_presignup" {
  function_name    = "${var.project_name}-cognito-presignup"
  filename         = data.archive_file.cognito_presignup.output_path
  source_code_hash = data.archive_file.cognito_presignup.output_base64sha256
  role             = aws_iam_role.cognito_presignup.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 10

  environment {
    variables = {
      ALLOWED_DOMAINS = join(",", var.allowed_email_domains)
    }
  }

  tags = {
    Name = "${var.project_name}-cognito-presignup"
  }
}

resource "aws_lambda_permission" "cognito_presignup" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cognito_presignup.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.pluto.arn
}

# -----------------------------------------------------------------------------
# COGNITO POST-CONFIRMATION LAMBDA (Queue n8n invitations)
# -----------------------------------------------------------------------------
# Queues new users for n8n invitation via SQS
# NOTE: OpenWebUI users are auto-created via oauth2-proxy trusted headers

resource "aws_secretsmanager_secret" "n8n_api_key" {
  name                    = "${var.project_name}/n8n_api_key"
  description             = "n8n API key for auto-inviting users"
  recovery_window_in_days = 0
}

# Note: After deployment, you must manually set the n8n API key:
# aws secretsmanager put-secret-value --secret-id pluto/n8n_api_key --secret-string "your-n8n-api-key"

# NOTE: OpenWebUI users are auto-created via oauth2-proxy trusted headers (X-Forwarded-Email)
# The Lambda-based user provisioning is only used for n8n invitations
# OpenWebUI API key secret is not needed

data "archive_file" "cognito_postconfirm" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/cognito_postconfirm"
  output_path = "${path.module}/../lambda/cognito_postconfirm.zip"
}

resource "aws_iam_role" "cognito_postconfirm" {
  name = "${var.project_name}-cognito-postconfirm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cognito_postconfirm_logs" {
  role       = aws_iam_role.cognito_postconfirm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# CloudWatch Log Group with retention
resource "aws_cloudwatch_log_group" "cognito_postconfirm" {
  name              = "/aws/lambda/${aws_lambda_function.cognito_postconfirm.function_name}"
  retention_in_days = 14 # Keep logs for 2 weeks

  tags = {
    Name = "${var.project_name}-cognito-postconfirm-logs"
  }
}

# PostConfirmation Lambda only sends messages to SQS, doesn't need secrets
# (Secrets are retrieved by the worker Lambda)

resource "aws_lambda_function" "cognito_postconfirm" {
  function_name    = "${var.project_name}-cognito-postconfirm"
  filename         = data.archive_file.cognito_postconfirm.output_path
  source_code_hash = data.archive_file.cognito_postconfirm.output_base64sha256
  role             = aws_iam_role.cognito_postconfirm.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 15

  environment {
    variables = {
      USER_PROVISIONING_QUEUE_URL = aws_sqs_queue.user_provisioning.url
    }
  }

  tags = {
    Name = "${var.project_name}-cognito-postconfirm"
  }
}

resource "aws_lambda_permission" "cognito_postconfirm" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cognito_postconfirm.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.pluto.arn
}