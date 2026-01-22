# -----------------------------------------------------------------------------
# APPLICATION SECRETS
# Secrets for LiteLLM, OpenWebUI, n8n, and Cognito
# -----------------------------------------------------------------------------

resource "random_id" "secrets_suffix" {
  byte_length = 4
}

# -----------------------------------------------------------------------------
# LITELLM SECRETS
# -----------------------------------------------------------------------------

resource "random_password" "litellm_master_key" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "litellm_master_key" {
  name                    = "${var.project_name}/litellm_master_key"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "litellm_master_key" {
  secret_id     = aws_secretsmanager_secret.litellm_master_key.id
  secret_string = "sk-${random_password.litellm_master_key.result}"
}

# -----------------------------------------------------------------------------
# OPENWEBUI SECRETS
# -----------------------------------------------------------------------------

resource "random_password" "webui_secret_key" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "webui_secret_key" {
  name                    = "${var.project_name}/webui_secret_key"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "webui_secret_key" {
  secret_id     = aws_secretsmanager_secret.webui_secret_key.id
  secret_string = random_password.webui_secret_key.result
}

# -----------------------------------------------------------------------------
# N8N SECRETS
# -----------------------------------------------------------------------------

resource "random_password" "n8n_encryption_key" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "n8n_encryption_key" {
  name                    = "${var.project_name}/n8n_encryption_key"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "n8n_encryption_key" {
  secret_id     = aws_secretsmanager_secret.n8n_encryption_key.id
  secret_string = random_password.n8n_encryption_key.result
}

# -----------------------------------------------------------------------------
# COGNITO SECRETS
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "cognito_client_secret" {
  name                    = "${var.project_name}/cognito_client_secret"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "cognito_client_secret" {
  secret_id     = aws_secretsmanager_secret.cognito_client_secret.id
  secret_string = aws_cognito_user_pool_client.alb.client_secret
}

# -----------------------------------------------------------------------------
# OAUTH2-PROXY SECRETS
# -----------------------------------------------------------------------------

resource "random_password" "oauth2_proxy_cookie_secret" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "oauth2_proxy_cookie_secret" {
  name                    = "${var.project_name}/oauth2_proxy_cookie_secret"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "oauth2_proxy_cookie_secret" {
  secret_id     = aws_secretsmanager_secret.oauth2_proxy_cookie_secret.id
  secret_string = base64encode(random_password.oauth2_proxy_cookie_secret.result)
}
