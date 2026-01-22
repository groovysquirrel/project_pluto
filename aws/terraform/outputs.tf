output "vpc_id" {
  value = aws_vpc.pluto.id
}

output "alb_dns_name" {
  value = aws_lb.pluto.dns_name
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.pluto.name
}

output "ecs_service_names" {
  value = {
    portal    = aws_ecs_service.portal.name
    litellm   = aws_ecs_service.litellm.name
    openwebui = aws_ecs_service.openwebui.name
    n8n       = aws_ecs_service.n8n.name
  }
}

output "db_endpoint" {
  value     = aws_db_proxy.pluto.endpoint
  sensitive = true
  description = "RDS Proxy endpoint (used by services)"
}

output "db_cluster_endpoint" {
  value     = aws_rds_cluster.pluto.endpoint
  sensitive = true
  description = "Direct Aurora cluster endpoint (for admin/debugging)"
}

output "ecr_repository_urls" {
  value = {
    for k, v in aws_ecr_repository.pluto : k => v.repository_url
  }
}

output "service_urls" {
  value = {
    for k, v in local.service_hosts : k => "https://${v}"
  }
}

output "region" {
  value = data.aws_region.current.name
}

output "cognito_user_pool_id" {
  value       = aws_cognito_user_pool.pluto.id
  description = "Cognito User Pool ID"
}

output "cognito_user_pool_client_id" {
  value       = aws_cognito_user_pool_client.alb.id
  description = "Cognito User Pool Client ID"
}

output "cognito_domain" {
  value       = var.cognito_custom_domain != "" ? var.cognito_custom_domain : "${aws_cognito_user_pool_domain.pluto.domain}.auth.${data.aws_region.current.name}.amazoncognito.com"
  description = "Cognito hosted UI domain (full domain for auth URLs)"
}

output "cognito_login_url" {
  value       = var.cognito_custom_domain != "" ? "https://${var.cognito_custom_domain}/login?client_id=${aws_cognito_user_pool_client.alb.id}&response_type=token&scope=email+openid+profile&redirect_uri=https://${local.domain_root}/" : "https://${aws_cognito_user_pool_domain.pluto.domain}.auth.${data.aws_region.current.name}.amazoncognito.com/login?client_id=${aws_cognito_user_pool_client.alb.id}&response_type=token&scope=email+openid+profile&redirect_uri=https://${local.domain_root}/"
  description = "Cognito hosted UI login URL for portal (implicit flow)"
}

output "internal_service_endpoints" {
  value = {
    portal    = "http://${local.internal_services.portal}:80"
    litellm   = "http://${local.internal_services.litellm}:4000"
    openwebui = "http://${local.internal_services.openwebui}:8080"
    n8n       = "http://${local.internal_services.n8n}:5678"
  }
  description = "Internal service discovery endpoints (use within ECS cluster)"
}

output "ses_domain_identity_arn" {
  value       = aws_ses_domain_identity.pluto.arn
  description = "SES domain identity ARN (for Cognito email configuration)"
}

output "ses_sending_email" {
  value       = aws_ses_email_identity.system.email
  description = "SES verified email address for sending"
}
