# AWS Deployment

This directory contains an AWS deployment for Project Pluto using ECS Fargate, ECR, RDS, EFS, and ALB with Cognito authentication.

## Architecture

```
Internet → ALB (TLS via ACM + Cognito Auth) → ECS Fargate Task
                                                    ├── Portal (nginx)
                                                    ├── OpenWebUI  ──→ LiteLLM (localhost:4000)
                                                    ├── LiteLLM    ──→ AWS Bedrock
                                                    └── n8n
                                                          ↓
                                              RDS PostgreSQL + EFS Storage
```

## What This Stack Creates

- **Networking**: VPC, public/private subnets, VPC Endpoints (ECR, Secrets Manager, CloudWatch, S3)
- **Load Balancing**: ALB with TLS termination (ACM) and Cognito SSO authentication
- **Compute**: ECS Fargate task with 4 containers (Portal, OpenWebUI, LiteLLM, n8n)
- **Database**: RDS PostgreSQL instance (shared by all services)
- **Storage**: EFS with access point for OpenWebUI persistent data
- **Container Registry**: ECR repositories for all container images
- **DNS**: Route53 records for service subdomains
- **Secrets**: Secrets Manager for database URLs, API keys, encryption keys
- **Authentication**: Cognito User Pool with custom domain for SSO

## Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform installed (>= 1.5.0)
- Docker installed and running
- Route53 hosted zone already exists

## Configuration

Copy `.env.example` to `.env` and update:

```bash
TF_VAR_project_name="pluto"
TF_VAR_hosted_zone_name="your-domain.com"
TF_VAR_subdomain_prefix=""  # Optional: results in pluto.your-domain.com
TF_VAR_cognito_custom_domain="auth.your-domain.com"
```

## Deploy

```bash
./pluto.sh deploy aws
```

The script will:
1. Validate prerequisites (AWS CLI, Terraform, Docker)
2. Provision infrastructure with Terraform
3. Build and push container images to ECR
4. Force ECS service to pull new images

## Teardown

```bash
./pluto.sh teardown aws
```

## Service URLs

After deployment, access services at:

| Service | URL |
|---------|-----|
| Portal | `https://<domain>/` |
| OpenWebUI | `https://openwebui.<domain>/` |
| LiteLLM | `https://litellm.<domain>/` |
| n8n | `https://n8n.<domain>/` |

## Authentication

All services are protected by **AWS Cognito** via ALB listener rules:

### OpenWebUI & n8n
- **Full authentication** on all paths
- Users must log in via Cognito before accessing the application
- First user to sign up becomes admin (controlled by Lambda pre-signup function)

### LiteLLM
- **Split authentication** by path for flexibility:
  - **API paths** (`/v1/*`, `/health/*`, `/chat/*`): No Cognito authentication
    - Uses LiteLLM's built-in API key authentication
    - Allows OpenWebUI and n8n to call the API programmatically
    - API key stored in Secrets Manager (`LITELLM_MASTER_KEY`)
  - **Web UI paths** (`/ui`, `/`, etc.): Protected by Cognito
    - Human users must log in to access the admin dashboard
    - Manage models, view usage, create API keys

### First-Time Setup
1. Deploy the stack: `./pluto.sh deploy aws`
2. Visit any service URL (e.g., `https://openwebui.your-domain.com`)
3. Click "Sign up" and create an account
4. The first account created automatically becomes an admin
5. Subsequent signups require admin approval (or auto-approve via Lambda configuration)

## Notes

- **Container Communication**: Containers communicate via localhost (127.0.0.1)
- **Bedrock Access**: IAM policy attached to task role allows `bedrock:InvokeModel`
- **Database**: Single shared RDS instance with separate databases per service
- **Secrets**: Automatically generated and stored in Secrets Manager

## Files

- `deploy.sh` - Terraform apply + ECR image push + ECS refresh
- `teardown.sh` - Terraform destroy
- `terraform/` - Infrastructure as code
- `portal/Dockerfile` - Portal container build
