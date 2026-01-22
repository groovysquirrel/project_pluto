# -----------------------------------------------------------------------------
# ECS (Elastic Container Service)
# Cluster, service discovery, task definitions, and services
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# ECS CLUSTER + LOGGING
# -----------------------------------------------------------------------------

resource "aws_ecs_cluster" "pluto" {
  name = "${var.project_name}-cluster"
}

resource "aws_cloudwatch_log_group" "pluto" {
  name              = "/${var.project_name}/ecs"
  retention_in_days = 30
}

# -----------------------------------------------------------------------------
# SERVICE DISCOVERY NAMESPACE (Private DNS for internal service discovery)
# -----------------------------------------------------------------------------

# Private DNS namespace allows services to be reached at servicename.pluto.local
resource "aws_service_discovery_private_dns_namespace" "pluto" {
  name        = "pluto.local"
  description = "Private DNS namespace for internal Pluto services"
  vpc         = aws_vpc.pluto.id

  tags = {
    Name = "${var.project_name}-internal-dns"
  }
}

# -----------------------------------------------------------------------------
# TASK DEFINITIONS
# -----------------------------------------------------------------------------

# Portal Task Definition
resource "aws_ecs_task_definition" "portal" {
  family                   = "${var.project_name}-portal"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "portal"
      image     = "${aws_ecr_repository.pluto["portal"].repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          name          = "portal"
          containerPort = 80
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.pluto.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "portal"
        }
      }
    }
  ])
}

# LiteLLM Task Definition
resource "aws_ecs_task_definition" "litellm" {
  family                   = "${var.project_name}-litellm"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    # OAuth2-Proxy sidecar - handles Cognito authentication for UI paths
    # API paths (/v1/*, /health/*, /chat/*) bypass auth for API key access
    {
      name      = "oauth2-proxy"
      image     = "quay.io/oauth2-proxy/oauth2-proxy:v7.6.0"
      essential = true
      portMappings = [
        {
          name          = "litellm"
          containerPort = 4180
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "OAUTH2_PROXY_PROVIDER"
          value = "oidc"
        },
        {
          name  = "OAUTH2_PROXY_OIDC_ISSUER_URL"
          value = "https://cognito-idp.${data.aws_region.current.name}.amazonaws.com/${aws_cognito_user_pool.pluto.id}"
        },
        {
          name  = "OAUTH2_PROXY_CLIENT_ID"
          value = aws_cognito_user_pool_client.alb.id
        },
        {
          name  = "OAUTH2_PROXY_REDIRECT_URL"
          value = "https://${local.service_hosts.litellm}/oauth2/callback"
        },
        {
          name  = "OAUTH2_PROXY_UPSTREAMS"
          value = "http://127.0.0.1:4000/"
        },
        {
          name  = "OAUTH2_PROXY_HTTP_ADDRESS"
          value = "0.0.0.0:4180"
        },
        {
          name  = "OAUTH2_PROXY_EMAIL_DOMAINS"
          value = "*"
        },
        {
          name  = "OAUTH2_PROXY_PASS_USER_HEADERS"
          value = "true"
        },
        {
          name  = "OAUTH2_PROXY_SET_XAUTHREQUEST"
          value = "true"
        },
        {
          name  = "OAUTH2_PROXY_SCOPE"
          value = "openid email profile"
        },
        {
          name  = "OAUTH2_PROXY_SKIP_PROVIDER_BUTTON"
          value = "true"
        },
        {
          name  = "OAUTH2_PROXY_REVERSE_PROXY"
          value = "true"
        },
        # Shared cookie domain for SSO across all services
        {
          name  = "OAUTH2_PROXY_COOKIE_DOMAINS"
          value = ".${local.domain_root}"
        },
        {
          name  = "OAUTH2_PROXY_WHITELIST_DOMAINS"
          value = ".${local.domain_root}"
        },
        # Skip auth for API paths - allows API key authentication
        {
          name  = "OAUTH2_PROXY_SKIP_AUTH_ROUTES"
          value = "^/v1/.*,^/health.*,^/chat/.*"
        }
      ]
      secrets = [
        {
          name      = "OAUTH2_PROXY_CLIENT_SECRET"
          valueFrom = aws_secretsmanager_secret.cognito_client_secret.arn
        },
        {
          name      = "OAUTH2_PROXY_COOKIE_SECRET"
          valueFrom = aws_secretsmanager_secret.oauth2_proxy_cookie_secret.arn
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.pluto.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "litellm-oauth2-proxy"
        }
      }
    },
    # LiteLLM - API server
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
        },
        {
          name  = "PROXY_ADMIN_ID"
          value = "jstmaurice@infotech.com"
        },
        {
          name  = "PROXY_BASE_URL"
          value = "https://${local.service_hosts.litellm}"
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
    }
  ])
}

# OpenWebUI Task Definition
resource "aws_ecs_task_definition" "openwebui" {
  family                   = "${var.project_name}-openwebui"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
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

  container_definitions = jsonencode([
    # =========================================================================
    # OpenWebUI Container
    # =========================================================================
    # Uses native OIDC authentication directly with Cognito.
    # No oauth2-proxy sidecar needed - simpler and more reliable.
    # =========================================================================
    {
      name      = "openwebui"
      image     = "${aws_ecr_repository.pluto["openwebui"].repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          name          = "openwebui"
          containerPort = 8080
          protocol      = "tcp"
        }
      ]
      environment = [
        # Force environment variables to take precedence over database config
        {
          name  = "ENABLE_PERSISTENT_CONFIG"
          value = "false"
        },
        {
          name  = "ENABLE_OAUTH_PERSISTENT_CONFIG"
          value = "false"
        },
        # =========================================================================
        # Native OIDC Authentication with Cognito
        # =========================================================================
        # OpenWebUI connects directly to Cognito for authentication.
        # This is simpler and more reliable than oauth2-proxy header passing.
        # =========================================================================
        {
          name  = "OPENID_PROVIDER_URL"
          value = "https://cognito-idp.${data.aws_region.current.name}.amazonaws.com/${aws_cognito_user_pool.pluto.id}/.well-known/openid-configuration"
        },
        {
          name  = "OAUTH_CLIENT_ID"
          value = aws_cognito_user_pool_client.alb.id
        },
        {
          name  = "OAUTH_PROVIDER_NAME"
          value = "Cognito"
        },
        {
          name  = "OAUTH_SCOPES"
          value = "openid email profile"
        },
        # Use 'name' claim for display name, 'email' for account identifier
        {
          name  = "OAUTH_USERNAME_CLAIM"
          value = "name"
        },
        {
          name  = "OAUTH_EMAIL_CLAIM"
          value = "email"
        },
        # Hide password login form - SSO only
        {
          name  = "ENABLE_LOGIN_FORM"
          value = "false"
        },
        {
          name  = "ENABLE_SIGNUP"
          value = "true"
        },
        {
          name  = "ENABLE_OAUTH_SIGNUP"
          value = "true"
        },
        # Auto-approve users created via OAuth (not "pending")
        {
          name  = "DEFAULT_USER_ROLE"
          value = "user"
        },
        # First user with this email gets admin role
        {
          name  = "WEBUI_ADMIN_EMAIL"
          value = "jstmaurice@infotech.com"
        },
        {
          name  = "WEBUI_URL"
          value = "https://${local.service_hosts.openwebui}"
        },
        # Core configuration
        {
          name  = "OPENAI_API_BASE_URL"
          value = "http://${local.internal_services.litellm}:4000/v1"
        },
        {
          name  = "ENABLE_OLLAMA_API"
          value = "false"
        },
        {
          name  = "ENABLE_OPENAI_API"
          value = "true"
        },
        # RAG configuration
        {
          name  = "VECTOR_DB"
          value = "chroma"
        },
        {
          name  = "RAG_EMBEDDING_ENGINE"
          value = "openai"
        },
        {
          name  = "RAG_EMBEDDING_MODEL"
          value = "text-embedding"
        },
        {
          name  = "RAG_OPENAI_API_BASE_URL"
          value = "http://${local.internal_services.litellm}:4000/v1"
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
        },
        {
          name      = "RAG_OPENAI_API_KEY"
          valueFrom = aws_secretsmanager_secret.litellm_master_key.arn
        },
        # Cognito OAuth client secret for native OIDC
        {
          name      = "OAUTH_CLIENT_SECRET"
          valueFrom = aws_secretsmanager_secret.cognito_client_secret.arn
        }
      ]
      mountPoints = [
        {
          sourceVolume  = "openwebui-data"
          containerPath = "/app/backend/data"
          readOnly      = false
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

# n8n Task Definition
resource "aws_ecs_task_definition" "n8n" {
  family                   = "${var.project_name}-n8n"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    # OAuth2-Proxy sidecar - handles Cognito authentication
    {
      name      = "oauth2-proxy"
      image     = "quay.io/oauth2-proxy/oauth2-proxy:v7.6.0"
      essential = true
      portMappings = [
        {
          name          = "n8n"
          containerPort = 4180
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "OAUTH2_PROXY_PROVIDER"
          value = "oidc"
        },
        {
          name  = "OAUTH2_PROXY_OIDC_ISSUER_URL"
          value = "https://cognito-idp.${data.aws_region.current.name}.amazonaws.com/${aws_cognito_user_pool.pluto.id}"
        },
        {
          name  = "OAUTH2_PROXY_CLIENT_ID"
          value = aws_cognito_user_pool_client.alb.id
        },
        {
          name  = "OAUTH2_PROXY_REDIRECT_URL"
          value = "https://${local.service_hosts.n8n}/oauth2/callback"
        },
        {
          name  = "OAUTH2_PROXY_UPSTREAMS"
          value = "http://127.0.0.1:5678/"
        },
        {
          name  = "OAUTH2_PROXY_HTTP_ADDRESS"
          value = "0.0.0.0:4180"
        },
        {
          name  = "OAUTH2_PROXY_EMAIL_DOMAINS"
          value = "*"
        },
        {
          name  = "OAUTH2_PROXY_PASS_USER_HEADERS"
          value = "true"
        },
        {
          name  = "OAUTH2_PROXY_SET_XAUTHREQUEST"
          value = "true"
        },
        {
          name  = "OAUTH2_PROXY_SCOPE"
          value = "openid email profile"
        },
        {
          name  = "OAUTH2_PROXY_SKIP_PROVIDER_BUTTON"
          value = "true"
        },
        {
          name  = "OAUTH2_PROXY_REVERSE_PROXY"
          value = "true"
        },
        # Shared cookie domain for SSO across all services
        {
          name  = "OAUTH2_PROXY_COOKIE_DOMAINS"
          value = ".${local.domain_root}"
        },
        {
          name  = "OAUTH2_PROXY_WHITELIST_DOMAINS"
          value = ".${local.domain_root}"
        }
      ]
      secrets = [
        {
          name      = "OAUTH2_PROXY_CLIENT_SECRET"
          valueFrom = aws_secretsmanager_secret.cognito_client_secret.arn
        },
        {
          name      = "OAUTH2_PROXY_COOKIE_SECRET"
          valueFrom = aws_secretsmanager_secret.oauth2_proxy_cookie_secret.arn
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.pluto.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "n8n-oauth2-proxy"
        }
      }
    },
    # N8N - workflow automation
    {
      name      = "n8n"
      image     = "${aws_ecr_repository.pluto["n8n"].repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = 5678
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "DB_TYPE"
          value = "postgresdb"
        },
        {
          name  = "DB_POSTGRESDB_HOST"
          value = aws_db_proxy.pluto.endpoint
        },
        {
          name  = "DB_POSTGRESDB_PORT"
          value = "5432"
        },
        {
          name  = "DB_POSTGRESDB_DATABASE"
          value = "n8n"
        },
        {
          name  = "DB_POSTGRESDB_USER"
          value = var.db_username
        },
        {
          name  = "WEBHOOK_URL"
          value = "https://n8n.${local.domain_root}/"
        },
        {
          name  = "DB_POSTGRESDB_SSL_ENABLED"
          value = "true"
        },
        {
          name  = "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED"
          value = "false"
        },
        {
          name  = "GENERIC_TIMEZONE"
          value = "America/New_York"
        },
        {
          name  = "TZ"
          value = "America/New_York"
        },
        {
          name  = "DB_POSTGRESDB_SSL_CONNECTION"
          value = "true"
        },
        {
          name  = "N8N_HOST"
          value = "n8n.${local.domain_root}"
        }
      ]
      secrets = [
        {
          name      = "DB_POSTGRESDB_PASSWORD"
          valueFrom = aws_secretsmanager_secret.db_password.arn
        },
        {
          name      = "N8N_ENCRYPTION_KEY"
          valueFrom = aws_secretsmanager_secret.n8n_encryption_key.arn
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.pluto.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "n8n"
        }
      }
    }
  ])
}

# -----------------------------------------------------------------------------
# ECS SERVICES
# -----------------------------------------------------------------------------

# Portal Service
resource "aws_ecs_service" "portal" {
  name            = "${var.project_name}-portal"
  cluster         = aws_ecs_cluster.pluto.id
  task_definition = aws_ecs_task_definition.portal.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_private_dns_namespace.pluto.arn

    service {
      port_name      = "portal"
      discovery_name = "portal"
      client_alias {
        dns_name = local.internal_services.portal
        port     = 80
      }
    }
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.portal.arn
    container_name   = "portal"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.https, aws_lb_listener_rule.openwebui, aws_lb_listener_rule.litellm, aws_lb_listener_rule.n8n]
}

# LiteLLM Service (Server - discoverable by other services)
resource "aws_ecs_service" "litellm" {
  name            = "${var.project_name}-litellm"
  cluster         = aws_ecs_cluster.pluto.id
  task_definition = aws_ecs_task_definition.litellm.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_private_dns_namespace.pluto.arn

    service {
      port_name      = "litellm"
      discovery_name = "litellm"
      client_alias {
        dns_name = local.internal_services.litellm
        port     = 4000
      }
    }
  }

  health_check_grace_period_seconds = 300

  load_balancer {
    target_group_arn = aws_lb_target_group.litellm.arn
    container_name   = "oauth2-proxy"
    container_port   = 4180
  }

  depends_on = [aws_lb_listener.https, aws_lb_listener_rule.litellm]
}

# OpenWebUI Service (Client - connects to litellm)
resource "aws_ecs_service" "openwebui" {
  name            = "${var.project_name}-openwebui"
  cluster         = aws_ecs_cluster.pluto.id
  task_definition = aws_ecs_task_definition.openwebui.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_private_dns_namespace.pluto.arn

    service {
      port_name      = "openwebui"
      discovery_name = "openwebui"
      client_alias {
        dns_name = local.internal_services.openwebui
        port     = 8080
      }
    }
  }

  health_check_grace_period_seconds = 600

  load_balancer {
    target_group_arn = aws_lb_target_group.openwebui.arn
    container_name   = "openwebui"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.https, aws_lb_listener_rule.openwebui, aws_ecs_service.litellm]
}

# n8n Service (Client - connects to litellm)
resource "aws_ecs_service" "n8n" {
  name            = "${var.project_name}-n8n"
  cluster         = aws_ecs_cluster.pluto.id
  task_definition = aws_ecs_task_definition.n8n.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_private_dns_namespace.pluto.arn

    service {
      port_name      = "n8n"
      discovery_name = "n8n"
      client_alias {
        dns_name = local.internal_services.n8n
        port     = 5678
      }
    }
  }

  health_check_grace_period_seconds = 300

  load_balancer {
    target_group_arn = aws_lb_target_group.n8n.arn
    container_name   = "oauth2-proxy"
    container_port   = 4180
  }

  depends_on = [aws_lb_listener.https, aws_lb_listener_rule.n8n]
}
