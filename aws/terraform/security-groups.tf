# -----------------------------------------------------------------------------
# SECURITY GROUPS
# All security group definitions for the infrastructure
# -----------------------------------------------------------------------------

# ALB Security Group (Public)
resource "aws_security_group" "alb" {
  name_prefix = "${var.project_name}-alb-"
  description = "ALB Public Access"
  vpc_id      = aws_vpc.pluto.id

  ingress {
    description = "HTTPS from World"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP Redirect"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-alb-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ECS Security Group (Private-ish)
# IMPORTANT: All ingress rules are managed via separate aws_security_group_rule resources below.
# Do NOT add inline ingress blocks here - they conflict with external rule management.
resource "aws_security_group" "ecs" {
  name_prefix = "${var.project_name}-ecs-"
  description = "ECS tasks access"
  vpc_id      = aws_vpc.pluto.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-ecs-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Allow ALB to reach oauth2-proxy on port 4180
resource "aws_security_group_rule" "alb_to_auth_proxy" {
  type                     = "ingress"
  from_port                = 4180
  to_port                  = 4180
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs.id
  source_security_group_id = aws_security_group.alb.id
  description              = "Auth-proxy from ALB"
}

# Allow container-to-container communication within ECS on specific service ports only
# Portal: 80, LiteLLM: 4000, OpenWebUI: 8080, n8n: 5678, auth-proxy: 4180
resource "aws_security_group_rule" "ecs_portal" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs.id
  source_security_group_id = aws_security_group.ecs.id
  description              = "Portal (nginx) from ECS"
}

resource "aws_security_group_rule" "ecs_litellm" {
  type                     = "ingress"
  from_port                = 4000
  to_port                  = 4000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs.id
  source_security_group_id = aws_security_group.ecs.id
  description              = "LiteLLM API from ECS"
}

resource "aws_security_group_rule" "ecs_auth_proxy" {
  type                     = "ingress"
  from_port                = 4180
  to_port                  = 4180
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs.id
  source_security_group_id = aws_security_group.ecs.id
  description              = "Auth-proxy from ECS"
}

resource "aws_security_group_rule" "ecs_n8n" {
  type                     = "ingress"
  from_port                = 5678
  to_port                  = 5678
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs.id
  source_security_group_id = aws_security_group.ecs.id
  description              = "n8n from ECS"
}

resource "aws_security_group_rule" "ecs_openwebui" {
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs.id
  source_security_group_id = aws_security_group.ecs.id
  description              = "OpenWebUI from ECS"
}

# RDS Security Group
resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  description = "Postgres access from ECS"
  vpc_id      = aws_vpc.pluto.id

  # Allow ECS containers to connect
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
    description     = "PostgreSQL from ECS"
  }

  # Allow RDS Proxy (same SG) to connect to Aurora
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    self        = true
    description = "RDS Proxy to Aurora (self-reference)"
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

# EFS Security Group
resource "aws_security_group" "efs" {
  name_prefix = "${var.project_name}-efs-"
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

# VPC Endpoints Security Group
resource "aws_security_group" "vpce" {
  name_prefix = "${var.project_name}-vpce-"
  description = "VPC Endpoints access"
  vpc_id      = aws_vpc.pluto.id

  ingress {
    description     = "HTTPS from ECS"
    from_port       = 443
    to_port         = 443
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
    Name = "${var.project_name}-vpce-sg"
  }
}
