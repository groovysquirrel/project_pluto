# -----------------------------------------------------------------------------
# DATABASE
# Aurora PostgreSQL Serverless v2, RDS Proxy, and related resources
# -----------------------------------------------------------------------------

resource "random_password" "db_password" {
  length  = 24
  special = false
}

resource "aws_db_subnet_group" "pluto" {
  name       = "${var.project_name}-db-subnets"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${var.project_name}-db-subnets"
  }
}

resource "aws_rds_cluster" "pluto" {
  cluster_identifier     = "${var.project_name}-db-cluster"
  engine                 = "aurora-postgresql"
  engine_mode            = "provisioned"
  engine_version         = "16.4"
  database_name          = var.db_name
  master_username        = var.db_username
  master_password        = random_password.db_password.result
  db_subnet_group_name   = aws_db_subnet_group.pluto.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Data protection settings
  deletion_protection      = true
  skip_final_snapshot      = false
  final_snapshot_identifier = "${var.project_name}-db-final-snapshot"

  # Enable Data API for Query Editor access
  enable_http_endpoint = true

  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 2.0
  }

  tags = {
    Name = "${var.project_name}-aurora"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_rds_cluster_instance" "pluto" {
  identifier           = "${var.project_name}-db"
  cluster_identifier   = aws_rds_cluster.pluto.id
  instance_class       = "db.serverless"
  engine               = aws_rds_cluster.pluto.engine
  engine_version       = aws_rds_cluster.pluto.engine_version
  publicly_accessible  = false

  tags = {
    Name = "${var.project_name}-db"
  }
}

# -----------------------------------------------------------------------------
# RDS PROXY (Connection Pooling)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "rds_proxy" {
  name = "${var.project_name}-rds-proxy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "rds.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "rds_proxy_secrets" {
  name = "${var.project_name}-rds-proxy-secrets"
  role = aws_iam_role.rds_proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = [aws_secretsmanager_secret.rds_proxy_auth.arn]
    }]
  })
}

# Secret for RDS Proxy authentication (username/password format)
resource "aws_secretsmanager_secret" "rds_proxy_auth" {
  name                    = "${var.project_name}/rds_proxy_auth"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "rds_proxy_auth" {
  secret_id = aws_secretsmanager_secret.rds_proxy_auth.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
  })
}

resource "aws_db_proxy" "pluto" {
  name                   = "${var.project_name}-proxy"
  debug_logging          = false
  engine_family          = "POSTGRESQL"
  idle_client_timeout    = 1800
  require_tls            = true
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_security_group_ids = [aws_security_group.rds.id]
  vpc_subnet_ids         = aws_subnet.private[*].id

  auth {
    auth_scheme               = "SECRETS"
    iam_auth                  = "DISABLED"
    secret_arn                = aws_secretsmanager_secret.rds_proxy_auth.arn
    client_password_auth_type = "POSTGRES_MD5"
  }

  tags = {
    Name = "${var.project_name}-rds-proxy"
  }
}

resource "aws_db_proxy_default_target_group" "pluto" {
  db_proxy_name = aws_db_proxy.pluto.name

  connection_pool_config {
    connection_borrow_timeout    = 120
    max_connections_percent      = 100
    max_idle_connections_percent = 50
  }
}

resource "aws_db_proxy_target" "pluto" {
  db_proxy_name          = aws_db_proxy.pluto.name
  target_group_name      = aws_db_proxy_default_target_group.pluto.name
  db_cluster_identifier  = aws_rds_cluster.pluto.id
}

# -----------------------------------------------------------------------------
# DATABASE SECRETS
# Connection strings for services
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.project_name}/db_password"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = random_password.db_password.result
}

resource "aws_secretsmanager_secret" "openwebui_database_url" {
  name                    = "${var.project_name}/openwebui_database_url"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "openwebui_database_url" {
  secret_id = aws_secretsmanager_secret.openwebui_database_url.id
  secret_string = "postgresql://${var.db_username}:${random_password.db_password.result}@${aws_db_proxy.pluto.endpoint}:5432/openwebui?sslmode=require"
}

resource "aws_secretsmanager_secret" "litellm_database_url" {
  name                    = "${var.project_name}/litellm_database_url"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "litellm_database_url" {
  secret_id = aws_secretsmanager_secret.litellm_database_url.id
  secret_string = "postgresql://${var.db_username}:${random_password.db_password.result}@${aws_db_proxy.pluto.endpoint}:5432/litellm?sslmode=require"
}

# Separate database for vector embeddings (pgvector)
resource "aws_secretsmanager_secret" "pgvector_database_url" {
  name                    = "${var.project_name}/pgvector_database_url"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "pgvector_database_url" {
  secret_id = aws_secretsmanager_secret.pgvector_database_url.id
  secret_string = "postgresql://${var.db_username}:${random_password.db_password.result}@${aws_db_proxy.pluto.endpoint}:5432/vectors?sslmode=require"
}
