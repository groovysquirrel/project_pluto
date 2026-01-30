# =============================================================================
# ECS (Elastic Container Service) Configuration
# =============================================================================
#
# This file defines the ECS cluster, task definitions, and services for Project Pluto.
# Each service runs as a Fargate task with an oauth2-proxy sidecar for authentication.
#
# ARCHITECTURE OVERVIEW:
# ----------------------
# Each ECS service follows a "sidecar pattern" where two containers run together:
#   1. oauth2-proxy container - Handles authentication with AWS Cognito
#   2. Application container - The actual service (portal, litellm, openwebui, n8n)
#
# TRAFFIC FLOW:
# -------------
# Internet → ALB → oauth2-proxy (port 4180) → Application (localhost:app_port)
#
# The ALB routes traffic to oauth2-proxy first, which:
#   - Validates the user's Cognito session
#   - Injects authentication headers (X-Forwarded-Email, X-Forwarded-User, etc.)
#   - Forwards the request to the application on localhost
#
# WHY LOCALHOST? Because containers in the same ECS task share a network namespace,
# they can communicate via 127.0.0.1 without needing service discovery.
#
# =============================================================================

# -----------------------------------------------------------------------------
# ECS CLUSTER + CLOUDWATCH LOGGING
# -----------------------------------------------------------------------------
# The ECS cluster hosts all Fargate tasks. CloudWatch Logs stores container logs
# with a 30-day retention period for troubleshooting and audit purposes.
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

# Private DNS namespace allows services to be reached at servicename.pluto.aws
resource "aws_service_discovery_private_dns_namespace" "pluto" {
  name        = "pluto.aws"
  description = "Private DNS namespace for internal Pluto services"
  vpc         = aws_vpc.pluto.id

  tags = {
    Name = "${var.project_name}-internal-dns"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# SERVICE DISCOVERY SERVICES (DNS-based, for Lambda access)
# -----------------------------------------------------------------------------
# These create actual Route53 DNS records that Lambda can resolve.
# Service Connect (used by ECS tasks) uses API-only discovery.
# Using both together requires different service names to avoid conflicts.
# -----------------------------------------------------------------------------

resource "aws_service_discovery_service" "openwebui" {
  name = "api.openwebui"  # Creates DNS: api.openwebui.pluto.aws

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.pluto.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_service_discovery_service" "n8n" {
  name = "api.n8n"  # Creates DNS: api.n8n.pluto.aws

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.pluto.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_service_discovery_service" "litellm" {
  name = "api.litellm"  # Creates DNS: api.litellm.pluto.aws

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.pluto.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

# =============================================================================
# TASK DEFINITIONS
# =============================================================================
# Each task definition specifies:
#   - Container images to run
#   - CPU and memory requirements
#   - Environment variables and secrets
#   - IAM roles for execution and task-level permissions
#   - Log configuration
#
# All services use the "sidecar pattern" with oauth2-proxy for authentication.
# =============================================================================

# -----------------------------------------------------------------------------
# PORTAL TASK DEFINITION
# -----------------------------------------------------------------------------
# The portal is a static landing page (HTML/CSS/JS) served by nginx.
# It provides links to all other services in the Pluto platform.
#
# CONTAINERS:
#   1. oauth2-proxy: Handles Cognito authentication
#   2. portal: Serves the static landing page
#
# RESOURCE ALLOCATION: 512 CPU, 1024 MB memory (minimal - it's just static files)
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "portal" {
  family                   = "${var.project_name}-portal"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    # OAuth2-Proxy - handles authentication
    {
      name      = "oauth2-proxy"
      image     = "quay.io/oauth2-proxy/oauth2-proxy:v7.6.0"
      essential = true
      portMappings = [
        {
          name          = "auth"
          containerPort = 4180
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "OAUTH2_PROXY_HTTP_ADDRESS", value = "0.0.0.0:4180" },
        { name = "OAUTH2_PROXY_PROVIDER", value = "oidc" },
        { name = "OAUTH2_PROXY_OIDC_ISSUER_URL", value = "https://cognito-idp.${data.aws_region.current.name}.amazonaws.com/${aws_cognito_user_pool.pluto.id}" },
        { name = "OAUTH2_PROXY_CLIENT_ID", value = aws_cognito_user_pool_client.alb.id },
        { name = "OAUTH2_PROXY_REDIRECT_URL", value = "https://${local.domain_root}/oauth2/callback" },
        { name = "OAUTH2_PROXY_UPSTREAMS", value = "http://127.0.0.1:80/" },
        { name = "OAUTH2_PROXY_EMAIL_DOMAINS", value = "*" },
        { name = "OAUTH2_PROXY_PASS_USER_HEADERS", value = "true" },
        { name = "OAUTH2_PROXY_SET_XAUTHREQUEST", value = "true" },
        { name = "OAUTH2_PROXY_SCOPE", value = "openid email profile" },
        { name = "OAUTH2_PROXY_SKIP_PROVIDER_BUTTON", value = "true" },
        { name = "OAUTH2_PROXY_REVERSE_PROXY", value = "true" },
        { name = "OAUTH2_PROXY_COOKIE_DOMAINS", value = ".${local.domain_root}" },
        { name = "OAUTH2_PROXY_COOKIE_NAME", value = "_oauth2_pluto" },
        { name = "OAUTH2_PROXY_WHITELIST_DOMAINS", value = ".${local.domain_root}" },
        { name = "OAUTH2_PROXY_INSECURE_OIDC_ALLOW_UNVERIFIED_EMAIL", value = "true" },
        { name = "OAUTH2_PROXY_COOKIE_SECURE", value = "true" },
        { name = "OAUTH2_PROXY_COOKIE_SAMESITE", value = "lax" },
        { name = "OAUTH2_PROXY_COOKIE_REFRESH", value = "1h" },
        { name = "OAUTH2_PROXY_COOKIE_EXPIRE", value = "168h" },
        { name = "OAUTH2_PROXY_CODE_CHALLENGE_METHOD", value = "S256" },
      ]
      secrets = [
        { name = "OAUTH2_PROXY_CLIENT_SECRET", valueFrom = aws_secretsmanager_secret.cognito_client_secret.arn },
        { name = "OAUTH2_PROXY_COOKIE_SECRET", valueFrom = aws_secretsmanager_secret.oauth2_proxy_cookie_secret.arn },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.pluto.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "portal-oauth2"
        }
      }
    },
    # Portal - Static landing page
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

# -----------------------------------------------------------------------------
# LITELLM TASK DEFINITION
# -----------------------------------------------------------------------------
# LiteLLM is an OpenAI-compatible API proxy that routes requests to AWS Bedrock.
# It provides a unified API for multiple LLM models (Claude, Llama, Nova, etc.)
#
# CONTAINERS:
#   1. oauth2-proxy: Authenticates web UI access, skips auth for API paths
#   2. litellm: The LiteLLM proxy server
#
# AUTHENTICATION STRATEGY:
#   - Web UI paths (/ui, /, etc.): Protected by Cognito via oauth2-proxy
#   - API paths (/v1/*, /health, etc.): No Cognito, uses LiteLLM API keys
#
# WHY? Other services (OpenWebUI, n8n) need to call the API programmatically
# and can't handle browser-based OAuth flows. They use API key authentication.
#
# RESOURCE ALLOCATION: 1024 CPU, 2048 MB memory (moderate - handles AI requests)
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "litellm" {
  family                   = "${var.project_name}-litellm"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    # OAuth2-Proxy - handles authentication
    {
      name      = "oauth2-proxy"
      image     = "quay.io/oauth2-proxy/oauth2-proxy:v7.6.0"
      essential = true
      portMappings = [
        {
          name          = "auth"
          containerPort = 4180
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "OAUTH2_PROXY_HTTP_ADDRESS", value = "0.0.0.0:4180" },
        { name = "OAUTH2_PROXY_PROVIDER", value = "oidc" },
        { name = "OAUTH2_PROXY_OIDC_ISSUER_URL", value = "https://cognito-idp.${data.aws_region.current.name}.amazonaws.com/${aws_cognito_user_pool.pluto.id}" },
        { name = "OAUTH2_PROXY_CLIENT_ID", value = aws_cognito_user_pool_client.alb.id },
        { name = "OAUTH2_PROXY_REDIRECT_URL", value = "https://${local.service_hosts.litellm}/oauth2/callback" },
        { name = "OAUTH2_PROXY_UPSTREAMS", value = "http://127.0.0.1:4000/" },
        { name = "OAUTH2_PROXY_EMAIL_DOMAINS", value = "*" },
        { name = "OAUTH2_PROXY_PASS_USER_HEADERS", value = "true" },
        { name = "OAUTH2_PROXY_SET_XAUTHREQUEST", value = "true" },
        { name = "OAUTH2_PROXY_USER_ID_CLAIM", value = "email" },
        { name = "OAUTH2_PROXY_SCOPE", value = "openid email profile" },
        { name = "OAUTH2_PROXY_SKIP_PROVIDER_BUTTON", value = "true" },
        { name = "OAUTH2_PROXY_REVERSE_PROXY", value = "true" },
        { name = "OAUTH2_PROXY_COOKIE_DOMAINS", value = ".${local.domain_root}" },
        { name = "OAUTH2_PROXY_COOKIE_NAME", value = "_oauth2_pluto" },
        { name = "OAUTH2_PROXY_WHITELIST_DOMAINS", value = ".${local.domain_root}" },
        { name = "OAUTH2_PROXY_INSECURE_OIDC_ALLOW_UNVERIFIED_EMAIL", value = "true" },
        { name = "OAUTH2_PROXY_COOKIE_SECURE", value = "true" },
        { name = "OAUTH2_PROXY_COOKIE_SAMESITE", value = "lax" },
        { name = "OAUTH2_PROXY_COOKIE_REFRESH", value = "1h" },
        { name = "OAUTH2_PROXY_COOKIE_EXPIRE", value = "168h" },
        { name = "OAUTH2_PROXY_CODE_CHALLENGE_METHOD", value = "S256" },
        { name = "OAUTH2_PROXY_SKIP_AUTH_ROUTES", value = "^/(v1|health|chat|key|model/info|models)(/.*)?$" },
      ]
      secrets = [
        { name = "OAUTH2_PROXY_CLIENT_SECRET", valueFrom = aws_secretsmanager_secret.cognito_client_secret.arn },
        { name = "OAUTH2_PROXY_COOKIE_SECRET", valueFrom = aws_secretsmanager_secret.oauth2_proxy_cookie_secret.arn },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.pluto.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "litellm-oauth2"
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
          name          = "litellm"
          containerPort = 4000
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "AWS_REGION_NAME", value = data.aws_region.current.name },
        { name = "STORE_MODEL_IN_DB", value = "True" },
        { name = "PROXY_ADMIN_ID", value = "jstmaurice@infotech.com" },
        { name = "PROXY_BASE_URL", value = "https://${local.service_hosts.litellm}" },
        { name = "GENERIC_CLIENT_ID", value = aws_cognito_user_pool_client.alb.id },
        { name = "GENERIC_AUTHORIZATION_ENDPOINT", value = "https://${var.cognito_custom_domain}/oauth2/authorize" },
        { name = "GENERIC_TOKEN_ENDPOINT", value = "https://${var.cognito_custom_domain}/oauth2/token" },
        { name = "GENERIC_USERINFO_ENDPOINT", value = "https://${var.cognito_custom_domain}/oauth2/userInfo" },
        { name = "GENERIC_SCOPE", value = "openid email profile" },
        # Logout redirect: oauth2-proxy → Cognito logout → Portal
        { name = "PROXY_LOGOUT_URL", value = "/oauth2/sign_out?rd=https%3A%2F%2F${var.cognito_custom_domain}%2Flogout%3Fclient_id%3D${aws_cognito_user_pool_client.alb.id}%26logout_uri%3Dhttps%253A%252F%252F${local.domain_root}" }
      ]
      secrets = [
        { name = "LITELLM_MASTER_KEY", valueFrom = aws_secretsmanager_secret.litellm_master_key.arn },
        { name = "DATABASE_URL", valueFrom = aws_secretsmanager_secret.litellm_database_url.arn },
        { name = "GENERIC_CLIENT_SECRET", valueFrom = aws_secretsmanager_secret.cognito_client_secret.arn }
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
# -----------------------------------------------------------------------------
# OPENWEBUI TASK DEFINITION
# -----------------------------------------------------------------------------
# OpenWebUI is a ChatGPT-like web interface for interacting with LLMs.
# It supports chat, document upload, RAG (retrieval augmented generation),
# and connects to LiteLLM for AI model access.
#
# CONTAINERS:
#   1. oauth2-proxy: Authenticates users with Cognito and injects headers
#   2. openwebui: The web chat interface
#
# AUTHENTICATION FLOW:
#   User → Cognito → oauth2-proxy → OpenWebUI (reads headers, auto-creates user)
#
# CRITICAL FIX APPLIED:
#   - Changed WEBUI_AUTH=false to rely on trusted headers
#   - This prevents the 403 errors on /api/v1/auths/signin
#   - Users are now auto-created when they first access OpenWebUI
#
# PERSISTENT STORAGE:
#   - Uses EFS (Elastic File System) to store uploaded documents
#   - Mounted at /app/backend/data inside the container
#
# RESOURCE ALLOCATION: 1024 CPU, 2048 MB memory (moderate - handles user sessions)
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "openwebui" {
  family                   = "${var.project_name}-openwebui"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  # EFS volume for persistent file storage (uploaded documents, user data)
  volume {
    name = "openwebui-data"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.pluto.id
      transit_encryption = "ENABLED"
      root_directory     = "/"
      authorization_config {
        access_point_id = aws_efs_access_point.openwebui.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    # =========================================================================
    # CONTAINER 1: OAUTH2-PROXY (Authentication Sidecar)
    # =========================================================================
    # This container sits in front of OpenWebUI and handles all authentication.
    # It communicates with AWS Cognito (OIDC provider) to validate user identity.
    #
    # WHAT IT DOES:
    #   1. Intercepts all incoming requests from the ALB
    #   2. Checks if the user has a valid Cognito session cookie
    #   3. If not authenticated, redirects to Cognito login
    #   4. After successful login, injects user info as HTTP headers
    #   5. Forwards the request to OpenWebUI on localhost:8080
    #
    # HEADERS INJECTED:
    #   When OAUTH2_PROXY_PASS_USER_HEADERS=true (direct proxy mode), oauth2-proxy sends:
    #   - X-Forwarded-Email: user's email address (e.g., justin@example.com)
    #   - X-Forwarded-User: user's email address or username
    #   - X-Forwarded-Groups: user's groups
    #   - X-Forwarded-Preferred-Username: user's preferred username
    #
    #   When OAUTH2_PROXY_SET_XAUTHREQUEST=true (nginx auth mode), it sends:
    #   - X-Auth-Request-Email, X-Auth-Request-User, etc.
    #
    #   We're using DIRECT PROXY MODE, so we get X-Forwarded-* headers!
    #   See: https://oauth2-proxy.github.io/oauth2-proxy/configuration/overview/
    #
    # These headers allow OpenWebUI to automatically create/login users without
    # requiring them to enter credentials again.
    # =========================================================================
    {
      name      = "oauth2-proxy"
      image     = "quay.io/oauth2-proxy/oauth2-proxy:v7.6.0"
      essential = true
      portMappings = [
        {
          name          = "auth"
          containerPort = 4180
          protocol      = "tcp"
        }
      ]
      environment = [
        # ---------------------------------------------------------------------
        # BASIC PROXY CONFIGURATION
        # ---------------------------------------------------------------------
        { name = "OAUTH2_PROXY_HTTP_ADDRESS", value = "0.0.0.0:4180" },
        { name = "OAUTH2_PROXY_PROVIDER", value = "oidc" },
        { name = "OAUTH2_PROXY_OIDC_ISSUER_URL", value = "https://cognito-idp.${data.aws_region.current.name}.amazonaws.com/${aws_cognito_user_pool.pluto.id}" },
        { name = "OAUTH2_PROXY_CLIENT_ID", value = aws_cognito_user_pool_client.alb.id },
        { name = "OAUTH2_PROXY_REDIRECT_URL", value = "https://${local.service_hosts.openwebui}/oauth2/callback" },

        # ---------------------------------------------------------------------
        # UPSTREAM TARGET (Where to forward authenticated requests)
        # ---------------------------------------------------------------------
        # Forwards to OpenWebUI container on localhost port 8080
        { name = "OAUTH2_PROXY_UPSTREAMS", value = "http://127.0.0.1:8080/" },

        # ---------------------------------------------------------------------
        # EMAIL VERIFICATION WORKAROUND
        # ---------------------------------------------------------------------
        # Cognito marks federated users (Google, SAML, etc.) as "unverified"
        # even though they're authenticated. This setting allows those users in.
        { name = "OAUTH2_PROXY_INSECURE_OIDC_ALLOW_UNVERIFIED_EMAIL", value = "true" },

        # ---------------------------------------------------------------------
        # SECURITY & COOKIE CONFIGURATION
        # ---------------------------------------------------------------------
        { name = "OAUTH2_PROXY_EMAIL_DOMAINS", value = "*" },
        { name = "OAUTH2_PROXY_COOKIE_DOMAINS", value = ".${local.domain_root}" },
        { name = "OAUTH2_PROXY_COOKIE_NAME", value = "_oauth2_pluto" },
        { name = "OAUTH2_PROXY_COOKIE_EXPIRE", value = "168h" },
        { name = "OAUTH2_PROXY_COOKIE_REFRESH", value = "1h" },
        { name = "OAUTH2_PROXY_WHITELIST_DOMAINS", value = ".${local.domain_root}" },
        { name = "OAUTH2_PROXY_COOKIE_SECURE", value = "true" },
        { name = "OAUTH2_PROXY_COOKIE_SAMESITE", value = "lax" },
        { name = "OAUTH2_PROXY_CODE_CHALLENGE_METHOD", value = "S256" },

        # ---------------------------------------------------------------------
        # HEADER PASSING CONFIGURATION (Critical for Trusted Header Auth)
        # ---------------------------------------------------------------------
        # These settings tell oauth2-proxy to inject user information as HTTP headers
        # that OpenWebUI can read to automatically authenticate users.
        { name = "OAUTH2_PROXY_PASS_USER_HEADERS", value = "true" },
        { name = "OAUTH2_PROXY_SET_XAUTHREQUEST", value = "true" },

        # Tell oauth2-proxy to use the "email" claim for the X-Forwarded-User header
        # Email is consistent across all identity providers (Google, Cognito, etc.)
        # and matches the userName field in OpenWebUI's SCIM API
        { name = "OAUTH2_PROXY_USER_ID_CLAIM", value = "email" },

        # Skip authentication for signup endpoint (needed for Lambda user creation)
        { name = "OAUTH2_PROXY_SKIP_AUTH_ROUTES", value = "^/api/v1/auths/signup$" },

        # ---------------------------------------------------------------------
        # OIDC & FLOW CONFIGURATION
        # ---------------------------------------------------------------------
        { name = "OAUTH2_PROXY_SCOPE", value = "openid email profile" },
        { name = "OAUTH2_PROXY_SKIP_PROVIDER_BUTTON", value = "true" },
        { name = "OAUTH2_PROXY_REVERSE_PROXY", value = "true" }
      ]
      secrets = [
        { name = "OAUTH2_PROXY_CLIENT_SECRET", valueFrom = aws_secretsmanager_secret.cognito_client_secret.arn },
        { name = "OAUTH2_PROXY_COOKIE_SECRET", valueFrom = aws_secretsmanager_secret.oauth2_proxy_cookie_secret.arn },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.pluto.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "openwebui-oauth2"
        }
      }
    },

    # =========================================================================
    # CONTAINER 2: OPENWEBUI (The Application)
    # =========================================================================
    # This is the actual OpenWebUI chat interface. It receives pre-authenticated
    # requests from oauth2-proxy with user identity in HTTP headers.
    #
    # TRUSTED HEADER AUTHENTICATION:
    # -------------------------------
    # OpenWebUI supports "trusted header auth" where it reads user info from
    # HTTP headers instead of requiring password login. This works because:
    #   1. oauth2-proxy already validated the user with Cognito
    #   2. oauth2-proxy injects X-Forwarded-Email and X-Forwarded-User headers
    #   3. OpenWebUI reads these headers and auto-creates/logs-in the user
    #
    # WHY THIS WAS FAILING:
    # ---------------------
    # - Initially got 403 Forbidden errors on /api/v1/auths/signin
    # - After setting WEBUI_AUTH=false, got 400 Bad Request instead
    # - Users were not being auto-created from the trusted headers
    # - Root cause: Known bug in OpenWebUI when WEBUI_AUTH=false
    #
    # THE FIX:
    # --------
    # - Keep WEBUI_AUTH=true (counterintuitive but necessary!)
    # - Add ENABLE_LOGIN_FORM=true
    # - Configure WEBUI_AUTH_TRUSTED_EMAIL_HEADER and WEBUI_AUTH_TRUSTED_NAME_HEADER
    # - This allows auto-sign-in from headers while keeping auth system functional
    # - See: https://github.com/open-webui/open-webui/issues/16193
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
        # ---------------------------------------------------------------------
        # AUTHENTICATION CONFIGURATION
        # ---------------------------------------------------------------------
        # Enable authentication via trusted headers only
        # WEBUI_AUTH=true keeps authentication enabled (required for trusted headers)
        # WEBUI_AUTH_TRUSTED_HEADER=true tells it to use headers instead of forms
        { name = "WEBUI_AUTH", value = "true" },
        { name = "WEBUI_AUTH_TRUSTED_HEADER", value = "true" },

        # ---------------------------------------------------------------------
        # TRUSTED HEADER CONFIGURATION
        # ---------------------------------------------------------------------
        # oauth2-proxy (with PASS_USER_HEADERS=true) sends X-Forwarded-* headers
        # OpenWebUI reads these headers to automatically authenticate users
        #
        # NOTE: Due to oauth2-proxy bug #3165, X-Forwarded-User contains Cognito sub (GUID)
        # instead of email. Using X-Forwarded-Email for both fields ensures consistent
        # authentication. Users can update their display names after account creation.
        { name = "WEBUI_AUTH_TRUSTED_EMAIL_HEADER", value = "X-Forwarded-Email" },
        { name = "WEBUI_AUTH_TRUSTED_NAME_HEADER", value = "X-Forwarded-Email" },

        # Redirect to Cognito logout when user signs out
        { name = "WEBUI_AUTH_SIGNOUT_REDIRECT_URL", value = "/oauth2/sign_out?rd=https%3A%2F%2Fauth.pluto.patternsatscale.com%2Flogout%3Fclient_id%3D77n2g266last0jim5h1c0qjckn%26logout_uri%3Dhttps%253A%252F%252Fpluto.patternsatscale.com" },

        # ---------------------------------------------------------------------
        # USER AUTO-CREATION
        # ---------------------------------------------------------------------
        # When a new email appears in the trusted headers, automatically create
        # a user account with the "user" role (not admin).
        # { name = "ENABLE_SIGNUP", value = "true" },
        { name = "DEFAULT_USER_ROLE", value = "user" },

        # Enable SCIM 2.0 API for programmatic user provisioning
        { name = "SCIM_ENABLED", value = "true" },

        # Authentication configuration for trusted header SSO
        # WEBUI_AUTH_TYPE explicitly sets trusted-header authentication mode
        # ENABLE_LOGIN_FORM=true required for proper trusted header detection
        # ENABLE_OAUTH_SIGNUP=true enables SSO user creation
        { name = "WEBUI_AUTH_TYPE", value = "trusted-header" },
        # { name = "ENABLE_LOGIN_FORM", value = "true" },
        # { name = "ENABLE_OAUTH_SIGNUP", value = "true" },

        # ---------------------------------------------------------------------
        # APPLICATION CONFIGURATION
        # ---------------------------------------------------------------------
        # Administrator email (first user with this email gets admin privileges)
        { name = "WEBUI_ADMIN_EMAIL", value = "jstmaurice@infotech.com" },

        # Public URL for OpenWebUI (used for generating links, webhooks, etc.)
        { name = "WEBUI_URL", value = "https://${local.service_hosts.openwebui}" },

        # ---------------------------------------------------------------------
        # LLM API CONFIGURATION
        # ---------------------------------------------------------------------
        # OpenWebUI connects to LiteLLM (not directly to Bedrock) for AI chat.
        # LiteLLM acts as a proxy/gateway to AWS Bedrock models.
        { name = "OPENAI_API_BASE_URL", value = "http://${local.internal_services.litellm}:4000/v1" },
        { name = "ENABLE_OLLAMA_API", value = "false" },  # Ollama is for local Docker only
        { name = "ENABLE_OPENAI_API", value = "true" },   # Use OpenAI-compatible API (LiteLLM)

        # ---------------------------------------------------------------------
        # RAG (Retrieval Augmented Generation) CONFIGURATION
        # ---------------------------------------------------------------------
        # RAG allows OpenWebUI to search through uploaded documents and use them
        # as context for AI responses. Requires a vector database and embeddings.
        { name = "VECTOR_DB", value = "pgvector" },                                              # Use PostgreSQL with pgvector extension
        { name = "RAG_EMBEDDING_ENGINE", value = "openai" },                                     # Use OpenAI-compatible embeddings
        { name = "RAG_EMBEDDING_MODEL", value = "text-embedding" },                              # Model name in LiteLLM config
        { name = "RAG_OPENAI_API_BASE_URL", value = "http://${local.internal_services.litellm}:4000/v1" }  # LiteLLM endpoint
      ]
      secrets = [
        { name = "OPENAI_API_KEY", valueFrom = aws_secretsmanager_secret.litellm_master_key.arn },
        { name = "WEBUI_SECRET_KEY", valueFrom = aws_secretsmanager_secret.webui_secret_key.arn },
        { name = "DATABASE_URL", valueFrom = aws_secretsmanager_secret.openwebui_database_url.arn },
        { name = "PGVECTOR_DB_URL", valueFrom = aws_secretsmanager_secret.pgvector_database_url.arn },
        { name = "RAG_OPENAI_API_KEY", valueFrom = aws_secretsmanager_secret.litellm_master_key.arn },
        { name = "SCIM_TOKEN", valueFrom = aws_secretsmanager_secret.openwebui_api_key.arn }
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

# -----------------------------------------------------------------------------
# N8N TASK DEFINITION
# -----------------------------------------------------------------------------
# n8n is a workflow automation platform (similar to Zapier/IFTTT).
# It allows users to create automated workflows connecting different services.
#
# CONTAINERS:
#   1. oauth2-proxy: Authenticates users with Cognito
#   2. n8n: The workflow automation application
#
# AUTHENTICATION STRATEGY:
#   - Web UI: Protected by Cognito via oauth2-proxy
#   - Webhook/API paths: Skip authentication (configured in oauth2-proxy)
#
# WHY SKIP AUTH ON WEBHOOKS? External services need to trigger workflows
# without going through Cognito authentication.
#
# DATABASE: Uses PostgreSQL (via RDS Proxy) for storing workflows and credentials
#
# RESOURCE ALLOCATION: 1024 CPU, 2048 MB memory (moderate - handles workflows)
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "n8n" {
  family                   = "${var.project_name}-n8n"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    # OAuth2-Proxy - handles authentication
    {
      name      = "oauth2-proxy"
      image     = "quay.io/oauth2-proxy/oauth2-proxy:v7.6.0"
      essential = true
      portMappings = [
        {
          name          = "auth"
          containerPort = 4180
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "OAUTH2_PROXY_HTTP_ADDRESS", value = "0.0.0.0:4180" },
        { name = "OAUTH2_PROXY_PROVIDER", value = "oidc" },
        { name = "OAUTH2_PROXY_OIDC_ISSUER_URL", value = "https://cognito-idp.${data.aws_region.current.name}.amazonaws.com/${aws_cognito_user_pool.pluto.id}" },
        { name = "OAUTH2_PROXY_CLIENT_ID", value = aws_cognito_user_pool_client.alb.id },
        { name = "OAUTH2_PROXY_REDIRECT_URL", value = "https://n8n.${local.domain_root}/oauth2/callback" },
        { name = "OAUTH2_PROXY_UPSTREAMS", value = "http://127.0.0.1:5678/" },
        { name = "OAUTH2_PROXY_EMAIL_DOMAINS", value = "*" },
        { name = "OAUTH2_PROXY_PASS_USER_HEADERS", value = "true" },
        { name = "OAUTH2_PROXY_SET_XAUTHREQUEST", value = "true" },
        { name = "OAUTH2_PROXY_SCOPE", value = "openid email profile" },
        { name = "OAUTH2_PROXY_SKIP_PROVIDER_BUTTON", value = "true" },
        { name = "OAUTH2_PROXY_REVERSE_PROXY", value = "true" },
        { name = "OAUTH2_PROXY_COOKIE_DOMAINS", value = ".${local.domain_root}" },
        { name = "OAUTH2_PROXY_COOKIE_NAME", value = "_oauth2_pluto" },
        { name = "OAUTH2_PROXY_WHITELIST_DOMAINS", value = ".${local.domain_root}" },
        { name = "OAUTH2_PROXY_INSECURE_OIDC_ALLOW_UNVERIFIED_EMAIL", value = "true" },
        { name = "OAUTH2_PROXY_COOKIE_SECURE", value = "true" },
        { name = "OAUTH2_PROXY_COOKIE_SAMESITE", value = "lax" },
        { name = "OAUTH2_PROXY_COOKIE_REFRESH", value = "1h" },
        { name = "OAUTH2_PROXY_COOKIE_EXPIRE", value = "168h" },
        { name = "OAUTH2_PROXY_CODE_CHALLENGE_METHOD", value = "S256" },
        { name = "OAUTH2_PROXY_SKIP_AUTH_ROUTES", value = "^/(webhook|api/v1)(/.*)?$" },
      ]
      secrets = [
        { name = "OAUTH2_PROXY_CLIENT_SECRET", valueFrom = aws_secretsmanager_secret.cognito_client_secret.arn },
        { name = "OAUTH2_PROXY_COOKIE_SECRET", valueFrom = aws_secretsmanager_secret.oauth2_proxy_cookie_secret.arn },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.pluto.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "n8n-oauth2"
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
          name          = "n8n"
          containerPort = 5678
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "DB_TYPE", value = "postgresdb" },
        { name = "DB_POSTGRESDB_HOST", value = aws_db_proxy.pluto.endpoint },
        { name = "DB_POSTGRESDB_PORT", value = "5432" },
        { name = "DB_POSTGRESDB_DATABASE", value = "n8n" },
        { name = "DB_POSTGRESDB_USER", value = var.db_username },
        { name = "WEBHOOK_URL", value = "https://n8n.${local.domain_root}/" },
        { name = "DB_POSTGRESDB_SSL_ENABLED", value = "true" },
        { name = "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED", value = "false" },
        { name = "GENERIC_TIMEZONE", value = "America/New_York" },
        { name = "TZ", value = "America/New_York" },
        { name = "DB_POSTGRESDB_SSL_CONNECTION", value = "true" },
        { name = "N8N_HOST", value = "n8n.${local.domain_root}" },
        { name = "N8N_USER_MANAGEMENT_DISABLED", value = "true" }
      ]
      secrets = [
        { name = "DB_POSTGRESDB_PASSWORD", valueFrom = aws_secretsmanager_secret.db_password.arn },
        { name = "N8N_ENCRYPTION_KEY", valueFrom = aws_secretsmanager_secret.n8n_encryption_key.arn }
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

# =============================================================================
# ECS SERVICES
# =============================================================================
# ECS Services manage the deployment and scaling of tasks. Each service:
#   - Ensures the desired number of tasks are always running
#   - Registers tasks with the Application Load Balancer (ALB)
#   - Provides service discovery for internal communication
#   - Handles health checks and automatic restarts
#
# NETWORKING:
#   - All services run in public subnets with public IPs (for pulling images)
#   - Security groups control access (only ALB can reach containers)
#   - Service Connect provides internal DNS (e.g., litellm.pluto.aws)
#
# LOAD BALANCING:
#   - ALB routes external traffic to oauth2-proxy (port 4180)
#   - oauth2-proxy forwards to the application container (various ports)
# =============================================================================

# -----------------------------------------------------------------------------
# PORTAL SERVICE
# -----------------------------------------------------------------------------
# Runs 1 task of the portal (static landing page). Simple, no scaling needed.
# -----------------------------------------------------------------------------
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
    container_name   = "oauth2-proxy"
    container_port   = 4180
  }

  health_check_grace_period_seconds = 120

  depends_on = [aws_lb_listener.https, aws_lb_listener_rule.openwebui, aws_lb_listener_rule.litellm, aws_lb_listener_rule.n8n]
}

# -----------------------------------------------------------------------------
# LITELLM SERVICE
# -----------------------------------------------------------------------------
# Runs 1 task of LiteLLM (the AI API gateway). Critical service that all other
# services depend on for AI functionality.
#
# SERVICE DISCOVERY: Registers as "litellm.pluto.aws" on port 4000 so other
# services can reach it without hardcoding IP addresses.
#
# HEALTH CHECK: 5-minute grace period because LiteLLM takes time to start and
# connect to the database.
# -----------------------------------------------------------------------------
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

  # DNS-based Service Discovery (for Lambda and external access)
  # A records only need container_name, not port
  service_registries {
    registry_arn   = aws_service_discovery_service.litellm.arn
    container_name = "litellm"
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

  load_balancer {
    target_group_arn = aws_lb_target_group.litellm.arn
    container_name   = "oauth2-proxy"
    container_port   = 4180
  }

  health_check_grace_period_seconds = 300

  depends_on = [aws_lb_listener.https, aws_lb_listener_rule.litellm]
}

# -----------------------------------------------------------------------------
# OPENWEBUI SERVICE
# -----------------------------------------------------------------------------
# Runs 1 task of OpenWebUI (the chat interface). Depends on LiteLLM service.
#
# SERVICE DISCOVERY: Registers as "openwebui.pluto.aws" on port 8080 for
# internal communication (though typically accessed externally via ALB).
#
# HEALTH CHECK: 10-minute grace period because OpenWebUI needs to:
#   1. Start the application
#   2. Connect to PostgreSQL (via RDS Proxy)
#   3. Connect to LiteLLM
#   4. Initialize the RAG vector database
#
# DEPENDENCIES: Waits for LiteLLM service to be ready before starting.
# -----------------------------------------------------------------------------
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

  # DNS-based Service Discovery (for Lambda and external access)
  # A records only need container_name, not port
  service_registries {
    registry_arn   = aws_service_discovery_service.openwebui.arn
    container_name = "openwebui"
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

  load_balancer {
    target_group_arn = aws_lb_target_group.openwebui.arn
    container_name   = "oauth2-proxy"
    container_port   = 4180
  }

  health_check_grace_period_seconds = 600

  depends_on = [aws_lb_listener.https, aws_lb_listener_rule.openwebui, aws_ecs_service.litellm]
}

# -----------------------------------------------------------------------------
# N8N SERVICE
# -----------------------------------------------------------------------------
# Runs 1 task of n8n (workflow automation). Can optionally connect to LiteLLM
# for AI-powered workflow nodes.
#
# SERVICE DISCOVERY: Registers as "n8n.pluto.aws" on port 5678
#
# HEALTH CHECK: 5-minute grace period for database connection and initialization.
# -----------------------------------------------------------------------------
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

  # DNS-based Service Discovery (for Lambda and external access)
  # A records only need container_name, not port
  service_registries {
    registry_arn   = aws_service_discovery_service.n8n.arn
    container_name = "n8n"
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

  load_balancer {
    target_group_arn = aws_lb_target_group.n8n.arn
    container_name   = "oauth2-proxy"
    container_port   = 4180
  }

  health_check_grace_period_seconds = 300

  depends_on = [aws_lb_listener.https, aws_lb_listener_rule.n8n]
}
