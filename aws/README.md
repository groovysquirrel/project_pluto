# AWS Deployment (Future)

This directory will contain AWS-specific deployment configuration.

## Planned Architecture

```
Internet → NLB (TLS via ACM) → Traefik (ECS) → Services (ECS Fargate)
                                                    ↓
                                              RDS PostgreSQL
                                              EFS (persistent storage)
```

## Key Components

| Component | AWS Service |
|-----------|-------------|
| Container Orchestration | ECS Fargate |
| Load Balancer | NLB + ACM certificates |
| Database | RDS for PostgreSQL |
| Persistent Storage | EFS (Elastic File System) |
| Secrets | AWS Secrets Manager |
| DNS | Route 53 |
| WAF | AWS WAF (optional) |

## Files (To Be Created)

- `deploy.sh` - AWS deployment script
- `teardown.sh` - AWS cleanup script  
- `terraform/` - Infrastructure as Code

## Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform installed
- Sufficient IAM permissions
