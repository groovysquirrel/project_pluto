# -----------------------------------------------------------------------------
# IAM
# ECS task execution and task roles with associated policies
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# ECS TASK EXECUTION ROLE
# Used by ECS to pull images and write logs
# -----------------------------------------------------------------------------

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.project_name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_secrets" {
  name   = "${var.project_name}-secrets"
  role   = aws_iam_role.ecs_task_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.litellm_master_key.arn,
          aws_secretsmanager_secret.webui_secret_key.arn,
          aws_secretsmanager_secret.openwebui_database_url.arn,
          aws_secretsmanager_secret.litellm_database_url.arn,
          aws_secretsmanager_secret.db_password.arn,
          aws_secretsmanager_secret.cognito_client_secret.arn,
          aws_secretsmanager_secret.n8n_encryption_key.arn,
          aws_secretsmanager_secret.oauth2_proxy_cookie_secret.arn
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# ECS TASK ROLE
# Used by running containers to access AWS services
# -----------------------------------------------------------------------------

resource "aws_iam_role" "ecs_task" {
  name               = "${var.project_name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

# Bedrock access for LiteLLM
resource "aws_iam_policy" "bedrock" {
  name        = "${var.project_name}-bedrock"
  description = "Allow LiteLLM to call Bedrock"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:ListFoundationModels"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_bedrock" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.bedrock.arn
}

# OpenSearch Serverless access
resource "aws_iam_policy" "opensearch" {
  name        = "${var.project_name}-opensearch"
  description = "Allow OpenWebUI to access OpenSearch Serverless"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "aoss:APIAccessAll"
        ]
        Resource = aws_opensearchserverless_collection.pluto.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_opensearch" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.opensearch.arn
}

# EFS access
resource "aws_iam_policy" "efs" {
  name        = "${var.project_name}-efs"
  description = "Allow ECS task to mount EFS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "elasticfilesystem:ClientMount",
        "elasticfilesystem:ClientWrite",
        "elasticfilesystem:ClientRootAccess"
      ]
      Resource = aws_efs_file_system.pluto.arn
      Condition = {
        StringEquals = {
          "elasticfilesystem:AccessPointArn" = aws_efs_access_point.openwebui.arn
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_efs" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.efs.arn
}
