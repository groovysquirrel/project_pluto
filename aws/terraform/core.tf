# -----------------------------------------------------------------------------
# CORE CONFIGURATION
# Terraform settings, providers, data sources, and locals
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  # REMOTE STATE BACKEND (Recommended)
  # Stores state in S3 instead of locally, preventing accidental commits.
  # To enable, uncomment and create the S3 bucket + DynamoDB table first:
  #   aws s3 mb s3://pluto-terraform-state-ACCOUNT_ID --region ca-central-1
  #   aws dynamodb create-table --table-name pluto-terraform-lock \
  #     --attribute-definitions AttributeName=LockID,AttributeType=S \
  #     --key-schema AttributeName=LockID,KeyType=HASH \
  #     --billing-mode PAY_PER_REQUEST --region ca-central-1
  #
  # backend "s3" {
  #   bucket         = "pluto-terraform-state-ACCOUNT_ID"  # Replace ACCOUNT_ID
  #   key            = "pluto/terraform.tfstate"
  #   region         = "ca-central-1"
  #   encrypt        = true
  #   dynamodb_table = "pluto-terraform-lock"  # For state locking
  # }

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

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

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

# -----------------------------------------------------------------------------
# LOCALS
# -----------------------------------------------------------------------------

locals {
  domain_root = var.subdomain_prefix != "" ? "${var.subdomain_prefix}.${var.hosted_zone_name}" : var.hosted_zone_name

  service_hosts = {
    openwebui = "openwebui.${local.domain_root}"
    litellm   = "litellm.${local.domain_root}"
    n8n       = "n8n.${local.domain_root}"
  }

  ecr_repos = {
    portal    = "${var.project_name}-portal"
    openwebui = "${var.project_name}-openwebui"
    litellm   = "${var.project_name}-litellm"
    n8n       = "${var.project_name}-n8n"
  }

  # Internal service discovery endpoints
  internal_services = {
    portal    = "portal.pluto.local"
    litellm   = "litellm.pluto.local"
    openwebui = "openwebui.pluto.local"
    n8n       = "n8n.pluto.local"
  }
}
