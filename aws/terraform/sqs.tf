# -----------------------------------------------------------------------------
# SQS QUEUE FOR N8N USER INVITATIONS
# -----------------------------------------------------------------------------
# Decouples Cognito signup from n8n API availability.
# PostConfirmation Lambda queues new user info, worker invites to n8n asynchronously.
# NOTE: OpenWebUI users are auto-created via oauth2-proxy trusted headers (no API call needed)

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
# LAMBDA FUNCTION - N8N Invitation Worker
# -----------------------------------------------------------------------------
# Processes n8n invitation messages from the queue
# NOTE: OpenWebUI users are auto-created via oauth2-proxy trusted headers

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

# CloudWatch Log Group with retention
resource "aws_cloudwatch_log_group" "user_provisioning_worker" {
  name              = "/aws/lambda/${aws_lambda_function.user_provisioning_worker.function_name}"
  retention_in_days = 14 # Keep logs for 2 weeks

  tags = {
    Name = "${var.project_name}-user-provisioning-worker-logs"
  }
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

# Allow Lambda to read n8n API key secret
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
      # NOTE: OpenWebUI users are auto-created via oauth2-proxy trusted headers
      # This Lambda only invites users to n8n
      N8N_URL            = "http://api.n8n.pluto.aws:5678"
      N8N_API_KEY_SECRET = aws_secretsmanager_secret.n8n_api_key.name
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
# CLOUDWATCH ALARMS - Monitor for failed user provisioning
# -----------------------------------------------------------------------------

# Alarm when messages appear in DLQ (indicates provisioning failure after all retries)
resource "aws_cloudwatch_metric_alarm" "user_provisioning_dlq" {
  alarm_name          = "${var.project_name}-user-provisioning-dlq-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = 0
  alarm_description   = "Alert when user provisioning messages fail after all retries and move to DLQ"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.user_provisioning_dlq.name
  }

  # TODO: Add SNS topic to send email/slack notifications
  # alarm_actions = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.project_name}-user-provisioning-dlq-alarm"
  }
}

# Alarm for Lambda errors (invocation errors, not business logic errors)
resource "aws_cloudwatch_metric_alarm" "user_provisioning_worker_errors" {
  alarm_name          = "${var.project_name}-user-provisioning-worker-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300 # 5 minutes
  statistic           = "Sum"
  threshold           = 5 # Alert if more than 5 errors in 5 minutes
  alarm_description   = "Alert when user provisioning worker Lambda has excessive errors"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.user_provisioning_worker.function_name
  }

  # TODO: Add SNS topic to send email/slack notifications
  # alarm_actions = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${var.project_name}-user-provisioning-worker-errors"
  }
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

output "user_provisioning_alarm_names" {
  description = "CloudWatch alarm names for user provisioning monitoring"
  value = {
    dlq_alarm    = aws_cloudwatch_metric_alarm.user_provisioning_dlq.alarm_name
    error_alarm  = aws_cloudwatch_metric_alarm.user_provisioning_worker_errors.alarm_name
  }
}
