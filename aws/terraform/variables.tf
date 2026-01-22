variable "project_name" {
  type        = string
  default     = "pluto"
  description = "Name prefix for AWS resources."
}

variable "hosted_zone_name" {
  type        = string
  description = "Route53 hosted zone name (example: example.com). Must already exist."
}

variable "subdomain_prefix" {
  type        = string
  default     = ""
  description = "Optional subdomain prefix (example: pluto). Leave blank for root zone."
}

variable "cognito_custom_domain" {
  type        = string
  default     = ""
  description = "Optional custom domain for Cognito (e.g. auth.pluto.example.com)."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.20.0.0/16"
  description = "CIDR block for the VPC."
}

variable "public_subnet_cidrs" {
  type        = list(string)
  default     = ["10.20.10.0/24", "10.20.20.0/24"]
  description = "Public subnet CIDRs (must match number of AZs used)."
}

variable "private_subnet_cidrs" {
  type        = list(string)
  default     = ["10.20.110.0/24", "10.20.120.0/24"]
  description = "Private subnet CIDRs (must match number of AZs used)."
}

variable "ecs_cpu" {
  type        = string
  default     = "2048"
  description = "ECS task CPU units for the combined task."
}

variable "ecs_memory" {
  type        = string
  default     = "4096"
  description = "ECS task memory (MiB) for the combined task."
}

variable "db_instance_class" {
  type        = string
  default     = "db.t4g.small"
  description = "RDS instance class."
}

variable "db_allocated_storage" {
  type        = number
  default     = 20
  description = "RDS allocated storage (GiB)."
}

variable "db_name" {
  type        = string
  default     = "pluto"
  description = "Database name for shared app usage."
}

variable "db_username" {
  type        = string
  default     = "pluto"
  description = "Database username."
}

variable "image_tag" {
  type        = string
  default     = "latest"
  description = "Image tag pushed to ECR for all services."
}

variable "allowed_email_domains" {
  type        = list(string)
  default     = ["patternsatscale.com", "infotech.com", "pluto.local"]
  description = "List of allowed email domains for Cognito registration."
}

# -----------------------------------------------------------------------------
# GOOGLE OAUTH CONFIGURATION
# -----------------------------------------------------------------------------

variable "enable_google_oauth" {
  type        = bool
  default     = true
  description = "Enable Google as a Cognito identity provider."
}

variable "google_oauth_client_id" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Google OAuth 2.0 Client ID from Google Cloud Console."
}

variable "google_oauth_client_secret" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Google OAuth 2.0 Client Secret from Google Cloud Console."
}
