# -----------------------------------------------------------------------------
# AMAZON SES - Email Service Configuration
# -----------------------------------------------------------------------------
# This configuration was captured from manual AWS Console setup.
# It provides email sending capability for Cognito and application notifications.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# SES DOMAIN IDENTITY
# -----------------------------------------------------------------------------

resource "aws_ses_domain_identity" "pluto" {
  domain = local.domain_root
}

resource "aws_ses_domain_dkim" "pluto" {
  domain = aws_ses_domain_identity.pluto.domain
}

# DKIM DNS Records - Required for email authentication
resource "aws_route53_record" "ses_dkim" {
  count           = 3
  zone_id         = data.aws_route53_zone.selected.zone_id
  name            = "${aws_ses_domain_dkim.pluto.dkim_tokens[count.index]}._domainkey.${local.domain_root}"
  type            = "CNAME"
  ttl             = 1800
  records         = ["${aws_ses_domain_dkim.pluto.dkim_tokens[count.index]}.dkim.amazonses.com"]
  allow_overwrite = true
}

# Domain verification (TXT record)
resource "aws_route53_record" "ses_verification" {
  zone_id         = data.aws_route53_zone.selected.zone_id
  name            = "_amazonses.${local.domain_root}"
  type            = "TXT"
  ttl             = 600
  records         = [aws_ses_domain_identity.pluto.verification_token]
  allow_overwrite = true
}

# Wait for domain verification
resource "aws_ses_domain_identity_verification" "pluto" {
  domain     = aws_ses_domain_identity.pluto.id
  depends_on = [aws_route53_record.ses_verification]
}

# -----------------------------------------------------------------------------
# SES EMAIL IDENTITY (for sending as system@domain)
# -----------------------------------------------------------------------------

resource "aws_ses_email_identity" "system" {
  email = "system@${local.domain_root}"

  depends_on = [aws_ses_domain_identity_verification.pluto]
}

# -----------------------------------------------------------------------------
# SES CONFIGURATION SET
# -----------------------------------------------------------------------------

resource "aws_ses_configuration_set" "pluto" {
  name = "my-first-configuration-set"  # Existing configuration set name

  reputation_metrics_enabled = true
  sending_enabled            = true

  # Note: delivery_options block not imported - will be added on next apply
}

# -----------------------------------------------------------------------------
# SES ACCOUNT-LEVEL VDM (Virtual Deliverability Manager)
# -----------------------------------------------------------------------------
# Note: This is an account-level setting. If you have other SES configurations
# in this account, this may affect them.

resource "aws_sesv2_account_vdm_attributes" "pluto" {
  vdm_enabled = "ENABLED"

  dashboard_attributes {
    engagement_metrics = "DISABLED"
  }

  guardian_attributes {
    optimized_shared_delivery = "ENABLED"
  }
}

# -----------------------------------------------------------------------------
# IAM USER FOR SMTP CREDENTIALS (Optional)
# -----------------------------------------------------------------------------
# Uncomment this section if you need SMTP credentials for applications
# that can't use IAM roles (e.g., external systems, legacy apps)

# resource "aws_iam_user" "ses_smtp" {
#   name = "${var.project_name}-ses-smtp"
#   path = "/system/"
# }
#
# resource "aws_iam_user_policy" "ses_smtp" {
#   name = "${var.project_name}-ses-smtp-policy"
#   user = aws_iam_user.ses_smtp.name
#
#   policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Effect   = "Allow"
#         Action   = "ses:SendRawEmail"
#         Resource = "*"
#         Condition = {
#           StringEquals = {
#             "ses:FromAddress" = "system@${local.domain_root}"
#           }
#         }
#       }
#     ]
#   })
# }
#
# resource "aws_iam_access_key" "ses_smtp" {
#   user = aws_iam_user.ses_smtp.name
# }
#
# # Store SMTP credentials in Secrets Manager
# resource "aws_secretsmanager_secret" "ses_smtp_credentials" {
#   name                    = "${var.project_name}/ses_smtp_credentials"
#   recovery_window_in_days = 0
# }
#
# resource "aws_secretsmanager_secret_version" "ses_smtp_credentials" {
#   secret_id = aws_secretsmanager_secret.ses_smtp_credentials.id
#   secret_string = jsonencode({
#     smtp_username = aws_iam_access_key.ses_smtp.id
#     # Note: SMTP password is derived from secret key, not the same!
#     # Use: aws ses get-smtp-password-v4 --secret-key <secret> --region <region>
#     access_key_id     = aws_iam_access_key.ses_smtp.id
#     secret_access_key = aws_iam_access_key.ses_smtp.secret
#   })
# }

# -----------------------------------------------------------------------------
# COGNITO SES INTEGRATION
# -----------------------------------------------------------------------------
# To use SES with Cognito, update the user pool email configuration:
#
# In cognito.tf, change:
#   email_configuration {
#     email_sending_account = "COGNITO_DEFAULT"
#   }
#
# To:
#   email_configuration {
#     email_sending_account  = "DEVELOPER"
#     from_email_address     = "system@${local.domain_root}"
#     source_arn             = aws_ses_domain_identity.pluto.arn
#     reply_to_email_address = "noreply@${local.domain_root}"
#   }
# -----------------------------------------------------------------------------
