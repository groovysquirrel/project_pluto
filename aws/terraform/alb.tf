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
  name_prefix = "portal"  # Use prefix for create_before_destroy
  port        = 4180  # oauth2-proxy port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.pluto.id
  target_type = "ip"
  health_check {
    path    = "/ping"  # oauth2-proxy health endpoint
    matcher = "200"
  }
  tags = {
    Name = "${var.project_name}-portal"
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "openwebui" {
  name_prefix = "owui"  # Use prefix for create_before_destroy (max 6 chars)
  port        = 4180  # oauth2-proxy port (trusted header auth)
  protocol    = "HTTP"
  vpc_id      = aws_vpc.pluto.id
  target_type = "ip"
  health_check {
    path    = "/ping"  # oauth2-proxy health endpoint
    matcher = "200"
  }
  tags = {
    Name = "${var.project_name}-openwebui"
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "litellm" {
  name_prefix = "litell"  # Use prefix for create_before_destroy (max 6 chars)
  port        = 4180  # oauth2-proxy port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.pluto.id
  target_type = "ip"
  health_check {
    path    = "/ping"  # oauth2-proxy health endpoint
    matcher = "200"
  }
  tags = {
    Name = "${var.project_name}-litellm"
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "n8n" {
  name_prefix = "n8n"  # Use prefix for create_before_destroy
  port        = 4180  # oauth2-proxy port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.pluto.id
  target_type = "ip"
  health_check {
    path    = "/ping"  # oauth2-proxy health endpoint
    matcher = "200"
  }
  tags = {
    Name = "${var.project_name}-n8n"
  }
  lifecycle {
    create_before_destroy = true
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

  # Default: Go to portal
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.portal.arn
  }
}

# -----------------------------------------------------------------------------
# LISTENER RULES
# -----------------------------------------------------------------------------

# OpenWebUI
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

# LiteLLM
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

# N8N
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
