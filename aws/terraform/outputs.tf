output "region" {
  value       = data.aws_region.current.name
  description = "AWS region used by Terraform."
}

output "domain_root" {
  value       = local.domain_root
  description = "Base domain used for service hostnames."
}

output "nlb_dns_name" {
  value       = aws_lb.pluto.dns_name
  description = "NLB DNS name."
}

output "service_urls" {
  value = {
    openwebui = "https://${local.service_hosts.openwebui}"
    litellm   = "https://${local.service_hosts.litellm}"
    chromadb  = "https://${local.service_hosts.chromadb}"
    ollama    = "https://${local.service_hosts.ollama}"
  }
  description = "Service URLs routed via the NLB and Traefik."
}

output "ecs_cluster_name" {
  value       = aws_ecs_cluster.pluto.name
  description = "ECS cluster name."
}

output "ecs_service_name" {
  value       = aws_ecs_service.pluto.name
  description = "ECS service name."
}

output "ecr_repository_urls" {
  value = {
    for key, repo in aws_ecr_repository.pluto : key => repo.repository_url
  }
  description = "ECR repository URLs for each service."
}
