terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "aws" {}

# -----------------------------------------------------------------------------
# DATA SOURCES
# -----------------------------------------------------------------------------

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_route53_zone" "selected" {
  name         = "${var.hosted_zone_name}."
  private_zone = false
}

# -----------------------------------------------------------------------------
# LOCALS
# -----------------------------------------------------------------------------

locals {
  domain_root = var.subdomain_prefix != "" ? "${var.subdomain_prefix}.${var.hosted_zone_name}" : var.hosted_zone_name

  service_hosts = {
    openwebui = "openwebui.${local.domain_root}"
    litellm   = "litellm.${local.domain_root}"
    chromadb  = "chromadb.${local.domain_root}"
    ollama    = "ollama.${local.domain_root}"
  }

  ecr_repos = {
    traefik   = "${var.project_name}-traefik"
    openwebui = "${var.project_name}-openwebui"
    litellm   = "${var.project_name}-litellm"
    chromadb  = "${var.project_name}-chromadb"
    ollama    = "${var.project_name}-ollama"
  }
}

# -----------------------------------------------------------------------------
# NETWORKING
# -----------------------------------------------------------------------------

resource "aws_vpc" "pluto" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "pluto" {
  vpc_id = aws_vpc.pluto.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.pluto.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-${count.index + 1}"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.pluto.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.project_name}-private-${count.index + 1}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.pluto.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.pluto.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.pluto.id

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# -----------------------------------------------------------------------------
# SECURITY GROUPS
# -----------------------------------------------------------------------------

resource "aws_security_group" "ecs" {
  name        = "${var.project_name}-ecs"
  description = "ECS tasks"
  vpc_id      = aws_vpc.pluto.id

  ingress {
    description = "Traefik entrypoint"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.pluto.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-ecs-sg"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds"
  description = "Postgres access from ECS"
  vpc_id      = aws_vpc.pluto.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

resource "aws_security_group" "efs" {
  name        = "${var.project_name}-efs"
  description = "EFS access from ECS"
  vpc_id      = aws_vpc.pluto.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-efs-sg"
  }
}

# -----------------------------------------------------------------------------
# ECR REPOSITORIES
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "pluto" {
  for_each = local.ecr_repos

  name = each.value

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-${each.key}"
  }
}

# -----------------------------------------------------------------------------
# EFS
# -----------------------------------------------------------------------------

resource "aws_efs_file_system" "pluto" {
  encrypted = true

  tags = {
    Name = "${var.project_name}-efs"
  }
}

resource "aws_efs_mount_target" "pluto" {
  count           = length(aws_subnet.private)
  file_system_id  = aws_efs_file_system.pluto.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "openwebui" {
  file_system_id = aws_efs_file_system.pluto.id

  root_directory {
    path = "/openwebui"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }

  tags = {
    Name = "${var.project_name}-openwebui"
  }
}

resource "aws_efs_access_point" "chromadb" {
  file_system_id = aws_efs_file_system.pluto.id

  root_directory {
    path = "/chromadb"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }

  tags = {
    Name = "${var.project_name}-chromadb"
  }
}

resource "aws_efs_access_point" "ollama" {
  file_system_id = aws_efs_file_system.pluto.id

  root_directory {
    path = "/ollama"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }

  tags = {
    Name = "${var.project_name}-ollama"
  }
}

# -----------------------------------------------------------------------------
# RDS
# -----------------------------------------------------------------------------

resource "random_password" "db_password" {
  length  = 24
  special = true
}

resource "aws_db_subnet_group" "pluto" {
  name       = "${var.project_name}-db-subnets"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${var.project_name}-db-subnets"
  }
}

resource "aws_db_instance" "pluto" {
  identifier             = "${var.project_name}-postgres"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = var.db_instance_class
  allocated_storage      = var.db_allocated_storage
  db_name                = var.db_name
  username               = var.db_username
  password               = random_password.db_password.result
  db_subnet_group_name   = aws_db_subnet_group.pluto.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  skip_final_snapshot    = true
  deletion_protection    = false

  tags = {
    Name = "${var.project_name}-postgres"
  }
}

# -----------------------------------------------------------------------------
# SECRETS
# -----------------------------------------------------------------------------

resource "random_password" "litellm_master_key" {
  length  = 32
  special = false
}

resource "random_password" "webui_secret_key" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "litellm_master_key" {
  name = "${var.project_name}/litellm_master_key"
}

resource "aws_secretsmanager_secret_version" "litellm_master_key" {
  secret_id     = aws_secretsmanager_secret.litellm_master_key.id
  secret_string = "sk-${random_password.litellm_master_key.result}"
}

resource "aws_secretsmanager_secret" "webui_secret_key" {
  name = "${var.project_name}/webui_secret_key"
}

resource "aws_secretsmanager_secret_version" "webui_secret_key" {
  secret_id     = aws_secretsmanager_secret.webui_secret_key.id
  secret_string = random_password.webui_secret_key.result
}

resource "aws_secretsmanager_secret" "openwebui_database_url" {
  name = "${var.project_name}/openwebui_database_url"
}

resource "aws_secretsmanager_secret_version" "openwebui_database_url" {
  secret_id = aws_secretsmanager_secret.openwebui_database_url.id
  secret_string = "postgresql://${var.db_username}:${random_password.db_password.result}@${aws_db_instance.pluto.address}:5432/${var.db_name}"
}

resource "aws_secretsmanager_secret" "litellm_database_url" {
  name = "${var.project_name}/litellm_database_url"
}

resource "aws_secretsmanager_secret_version" "litellm_database_url" {
  secret_id = aws_secretsmanager_secret.litellm_database_url.id
  secret_string = "postgresql://${var.db_username}:${random_password.db_password.result}@${aws_db_instance.pluto.address}:5432/${var.db_name}"
}

# -----------------------------------------------------------------------------
# ECS + LOGGING
# -----------------------------------------------------------------------------

resource "aws_ecs_cluster" "pluto" {
  name = "${var.project_name}-cluster"
}

resource "aws_cloudwatch_log_group" "pluto" {
  name              = "/${var.project_name}/ecs"
  retention_in_days = 30
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.project_name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task" {
  name               = "${var.project_name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

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

resource "aws_ecs_task_definition" "pluto" {
  family                   = "${var.project_name}-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ecs_cpu
  memory                   = var.ecs_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  volume {
    name = "openwebui-data"

    efs_volume_configuration {
      file_system_id          = aws_efs_file_system.pluto.id
      transit_encryption      = "ENABLED"
      root_directory          = "/"
      authorization_config {
        access_point_id = aws_efs_access_point.openwebui.id
        iam             = "ENABLED"
      }
    }
  }

  volume {
    name = "chromadb-data"

    efs_volume_configuration {
      file_system_id          = aws_efs_file_system.pluto.id
      transit_encryption      = "ENABLED"
      root_directory          = "/"
      authorization_config {
        access_point_id = aws_efs_access_point.chromadb.id
        iam             = "ENABLED"
      }
    }
  }

  volume {
    name = "ollama-data"

    efs_volume_configuration {
      file_system_id          = aws_efs_file_system.pluto.id
      transit_encryption      = "ENABLED"
      root_directory          = "/"
      authorization_config {
        access_point_id = aws_efs_access_point.ollama.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = "traefik"
      image     = "${aws_ecr_repository.pluto["traefik"].repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = 80
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.pluto.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "traefik"
        }
      }
    },
    {
      name      = "litellm"
      image     = "${aws_ecr_repository.pluto["litellm"].repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = 4000
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "AWS_REGION_NAME"
          value = data.aws_region.current.name
        },
        {
          name  = "STORE_MODEL_IN_DB"
          value = "True"
        }
      ]
      secrets = [
        {
          name      = "LITELLM_MASTER_KEY"
          valueFrom = aws_secretsmanager_secret.litellm_master_key.arn
        },
        {
          name      = "DATABASE_URL"
          valueFrom = aws_secretsmanager_secret.litellm_database_url.arn
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.pluto.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "litellm"
        }
      }
    },
    {
      name      = "chromadb"
      image     = "${aws_ecr_repository.pluto["chromadb"].repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = 8000
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "IS_PERSISTENT"
          value = "TRUE"
        },
        {
          name  = "ANONYMIZED_TELEMETRY"
          value = "FALSE"
        }
      ]
      mountPoints = [
        {
          sourceVolume  = "chromadb-data"
          containerPath = "/chroma/chroma"
          readOnly      = false
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.pluto.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "chromadb"
        }
      }
    },
    {
      name      = "ollama"
      image     = "${aws_ecr_repository.pluto["ollama"].repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = 11434
          protocol      = "tcp"
        }
      ]
      mountPoints = [
        {
          sourceVolume  = "ollama-data"
          containerPath = "/root/.ollama"
          readOnly      = false
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.pluto.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "ollama"
        }
      }
    },
    {
      name      = "openwebui"
      image     = "${aws_ecr_repository.pluto["openwebui"].repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = 8080
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "OPENAI_API_BASE_URL"
          value = "http://127.0.0.1:4000/v1"
        },
        {
          name  = "ENABLE_OLLAMA_API"
          value = "false"
        },
        {
          name  = "ENABLE_OPENAI_API"
          value = "true"
        },
        {
          name  = "CHROMA_HTTP_HOST"
          value = "127.0.0.1"
        },
        {
          name  = "CHROMA_HTTP_PORT"
          value = "8000"
        },
        {
          name  = "RAG_EMBEDDING_ENGINE"
          value = "ollama"
        },
        {
          name  = "RAG_EMBEDDING_MODEL"
          value = "nomic-embed-text"
        },
        {
          name  = "OLLAMA_BASE_URL"
          value = "http://127.0.0.1:11434"
        },
        {
          name  = "WEBUI_AUTH"
          value = "true"
        },
        {
          name  = "ENABLE_SIGNUP"
          value = "true"
        },
        {
          name  = "DEFAULT_USER_ROLE"
          value = "pending"
        }
      ]
      secrets = [
        {
          name      = "OPENAI_API_KEY"
          valueFrom = aws_secretsmanager_secret.litellm_master_key.arn
        },
        {
          name      = "WEBUI_SECRET_KEY"
          valueFrom = aws_secretsmanager_secret.webui_secret_key.arn
        },
        {
          name      = "DATABASE_URL"
          valueFrom = aws_secretsmanager_secret.openwebui_database_url.arn
        }
      ]
      mountPoints = [
        {
          sourceVolume  = "openwebui-data"
          containerPath = "/app/backend/data"
          readOnly      = false
        }
      ]
      dependsOn = [
        {
          containerName = "litellm"
          condition     = "START"
        },
        {
          containerName = "chromadb"
          condition     = "START"
        },
        {
          containerName = "ollama"
          condition     = "START"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.pluto.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "openwebui"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "pluto" {
  name            = "${var.project_name}-service"
  cluster         = aws_ecs_cluster.pluto.id
  task_definition = aws_ecs_task_definition.pluto.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.traefik.arn
    container_name   = "traefik"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.https]
}

# -----------------------------------------------------------------------------
# LOAD BALANCER + ACM
# -----------------------------------------------------------------------------

resource "aws_lb" "pluto" {
  name               = "${var.project_name}-nlb"
  load_balancer_type = "network"
  internal           = false
  subnets            = aws_subnet.public[*].id

  enable_cross_zone_load_balancing = true

  tags = {
    Name = "${var.project_name}-nlb"
  }
}

resource "aws_lb_target_group" "traefik" {
  name        = "${var.project_name}-traefik"
  port        = 80
  protocol    = "TCP"
  vpc_id      = aws_vpc.pluto.id
  target_type = "ip"

  health_check {
    protocol = "TCP"
    port     = "80"
  }
}

resource "aws_acm_certificate" "pluto" {
  domain_name               = local.domain_root
  validation_method         = "DNS"
  subject_alternative_names = var.subdomain_prefix != "" ? ["*.${local.domain_root}", "${local.domain_root}"] : ["*.${local.domain_root}"]

  tags = {
    Name = "${var.project_name}-cert"
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.pluto.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.selected.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "pluto" {
  certificate_arn         = aws_acm_certificate.pluto.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.pluto.arn
  port              = 443
  protocol          = "TLS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.pluto.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.traefik.arn
  }
}

# -----------------------------------------------------------------------------
# ROUTE53 RECORDS
# -----------------------------------------------------------------------------

resource "aws_route53_record" "services" {
  for_each = local.service_hosts

  zone_id = data.aws_route53_zone.selected.zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_lb.pluto.dns_name
    zone_id                = aws_lb.pluto.zone_id
    evaluate_target_health = false
  }
}

# -----------------------------------------------------------------------------
# IAM DATA
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}
