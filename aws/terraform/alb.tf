# -----------------------------------------------------------------------------
# APPLICATION LOAD BALANCER
# ALB, target groups, listeners, and listener rules
# -----------------------------------------------------------------------------

resource "aws_lb" "pluto" {
  name               = "${var.project_name}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]

  enable_cross_zone_load_balancing = true

  tags = {
    Name = "${var.project_name}-alb"
  }
}

# -----------------------------------------------------------------------------
# TARGET GROUPS
# -----------------------------------------------------------------------------

resource "aws_lb_target_group" "portal" {
  name        = "${var.project_name}-portal"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.pluto.id
  target_type = "ip"
  health_check {
    path = "/"
    matcher = "200-302"
  }
}

resource "aws_lb_target_group" "openwebui" {
  name        = "${var.project_name}-openwebui"
  port        = 8080  # OpenWebUI direct (native OIDC, no oauth2-proxy)
  protocol    = "HTTP"
  vpc_id      = aws_vpc.pluto.id
  target_type = "ip"
  health_check {
    path    = "/health"  # OpenWebUI health endpoint
    matcher = "200"
  }
}

resource "aws_lb_target_group" "litellm" {
  name        = "${var.project_name}-litellm"
  port        = 4180  # oauth2-proxy port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.pluto.id
  target_type = "ip"
  health_check {
    path    = "/ping"  # oauth2-proxy health endpoint
    matcher = "200"
  }
}

resource "aws_lb_target_group" "n8n" {
  name        = "${var.project_name}-n8n"
  port        = 4180  # oauth2-proxy port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.pluto.id
  target_type = "ip"
  health_check {
    path    = "/ping"  # oauth2-proxy health endpoint
    matcher = "200"
  }
}

# -----------------------------------------------------------------------------
# LISTENERS
# -----------------------------------------------------------------------------

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.pluto.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.pluto.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.pluto.certificate_arn

  # Default: Go to Portal
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.portal.arn
  }
}

# -----------------------------------------------------------------------------
# LISTENER RULES
# -----------------------------------------------------------------------------

# OpenWebUI - oauth2-proxy handles authentication, no ALB Cognito needed
resource "aws_lb_listener_rule" "openwebui" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.openwebui.arn
  }

  condition {
    host_header {
      values = [local.service_hosts.openwebui]
    }
  }
}

# LiteLLM - oauth2-proxy handles authentication
# API paths bypass auth via OAUTH2_PROXY_SKIP_AUTH_ROUTES in the container
resource "aws_lb_listener_rule" "litellm" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 190

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.litellm.arn
  }

  condition {
    host_header {
      values = [local.service_hosts.litellm]
    }
  }
}

# N8N - oauth2-proxy handles authentication
resource "aws_lb_listener_rule" "n8n" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 300

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.n8n.arn
  }

  condition {
    host_header {
      values = [local.service_hosts.n8n]
    }
  }
}
