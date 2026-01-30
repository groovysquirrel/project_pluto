# -----------------------------------------------------------------------------
# SQS QUEUE FOR USER PROVISIONING
# -----------------------------------------------------------------------------
# Decouples Cognito user creation from OpenWebUI/n8n API availability.
# Lambda puts new user info in queue, worker processes asynchronously.

# Dead Letter Queue - stores messages that fail after max retries
resource "aws_sqs_queue" "user_provisioning_dlq" {
  name                      = "${var.project_name}-user-provisioning-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = {
    Name = "${var.project_name}-user-provisioning-dlq"
  }
}

# Main Queue - receives new user provisioning requests
resource "aws_sqs_queue" "user_provisioning" {
  name                       = "${var.project_name}-user-provisioning"
  visibility_timeout_seconds = 90  # Worker has 90s to process (Lambda timeout is 60s)
  message_retention_seconds  = 345600 # 4 days
  receive_wait_time_seconds  = 20  # Long polling

  # Retry policy
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.user_provisioning_dlq.arn
    maxReceiveCount     = 5 # Try 5 times before sending to DLQ
  })

  tags = {
    Name = "${var.project_name}-user-provisioning"
  }
}

# Allow Cognito PostConfirm Lambda to send messages to queue
resource "aws_iam_role_policy" "cognito_postconfirm_sqs" {
  name = "${var.project_name}-cognito-postconfirm-sqs"
  role = aws_iam_role.cognito_postconfirm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:GetQueueUrl"
        ]
        Resource = aws_sqs_queue.user_provisioning.arn
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# LAMBDA FUNCTION - SQS Worker
# -----------------------------------------------------------------------------
# Processes user provisioning messages from the queue
# Creates users in OpenWebUI and invites to n8n

data "archive_file" "user_provisioning_worker" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/user_provisioning_worker"
  output_path = "${path.module}/../lambda/user_provisioning_worker.zip"
}

resource "aws_iam_role" "user_provisioning_worker" {
  name = "${var.project_name}-user-provisioning-worker"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "user_provisioning_worker_basic" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.user_provisioning_worker.name
}

# Allow Lambda to access VPC (required for private DNS resolution)
resource "aws_iam_role_policy_attachment" "user_provisioning_worker_vpc" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  role       = aws_iam_role.user_provisioning_worker.name
}

# Allow Lambda to read from SQS queue
resource "aws_iam_role_policy" "user_provisioning_worker_sqs" {
  name = "${var.project_name}-user-provisioning-worker-sqs"
  role = aws_iam_role.user_provisioning_worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.user_provisioning.arn
      }
    ]
  })
}

# Allow Lambda to read secrets (OpenWebUI and n8n API keys)
resource "aws_iam_role_policy" "user_provisioning_worker_secrets" {
  name = "${var.project_name}-user-provisioning-worker-secrets"
  role = aws_iam_role.user_provisioning_worker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.openwebui_api_key.arn,
          aws_secretsmanager_secret.n8n_api_key.arn
        ]
      }
    ]
  })
}

resource "aws_lambda_function" "user_provisioning_worker" {
  function_name    = "${var.project_name}-user-provisioning-worker"
  filename         = data.archive_file.user_provisioning_worker.output_path
  source_code_hash = data.archive_file.user_provisioning_worker.output_base64sha256
  role             = aws_iam_role.user_provisioning_worker.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 60

  environment {
    variables = {
      # Use DNS-based Service Discovery endpoints (private namespace)
      # These are created by traditional Service Discovery and resolvable from Lambda
      # Different from Service Connect which uses API-only discovery
      OPENWEBUI_URL            = "http://api.openwebui.pluto.aws:8080"
      OPENWEBUI_API_KEY_SECRET = aws_secretsmanager_secret.openwebui_api_key.name
      N8N_URL                  = "http://api.n8n.pluto.aws:5678"
      N8N_API_KEY_SECRET       = aws_secretsmanager_secret.n8n_api_key.name
    }
  }

  # VPC configuration required to access private DNS namespace
  vpc_config {
    subnet_ids         = aws_subnet.public[*].id
    security_group_ids = [aws_security_group.ecs.id]
  }

  tags = {
    Name = "${var.project_name}-user-provisioning-worker"
  }
}

# Connect Lambda to SQS queue (event source mapping)
resource "aws_lambda_event_source_mapping" "user_provisioning_worker" {
  event_source_arn = aws_sqs_queue.user_provisioning.arn
  function_name    = aws_lambda_function.user_provisioning_worker.arn
  batch_size       = 1 # Process one user at a time
  enabled          = true
}

# -----------------------------------------------------------------------------
# OUTPUTS
# -----------------------------------------------------------------------------

output "user_provisioning_queue_url" {
  description = "URL of the user provisioning SQS queue"
  value       = aws_sqs_queue.user_provisioning.url
}

output "user_provisioning_dlq_url" {
  description = "URL of the user provisioning dead letter queue"
  value       = aws_sqs_queue.user_provisioning_dlq.url
}
