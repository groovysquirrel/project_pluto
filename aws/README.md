# AWS Deployment

This directory contains a simple AWS deployment for Project Pluto using ECS Fargate, ECR, RDS, and EFS.

## Architecture

```
Internet → NLB (TLS via ACM) → Traefik (ECS task) → OpenWebUI / LiteLLM / ChromaDB / Ollama
                                                          ↓
                                                    RDS PostgreSQL
                                                    EFS (persistent storage)
```

## What This Stack Creates

- New VPC, public/private subnets, and routing
- NLB with TLS termination (ACM cert + Route53 validation)
- ECS Fargate task with 5 containers (Traefik, OpenWebUI, LiteLLM, ChromaDB, Ollama)
- RDS PostgreSQL instance
- EFS with access points for OpenWebUI, ChromaDB, and Ollama
- ECR repositories for all containers
- Route53 records for service subdomains
- Secrets Manager entries for database URLs and API keys

## Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform installed
- Docker installed and running
- Route53 hosted zone already exists

## Deploy

Run:

```
./aws/deploy.sh
```

The script will prompt for:
- Route53 hosted zone (example: `example.com`)
- Optional subdomain prefix (example: `pluto`)

If the hosted zone does not exist, deployment stops with an error.

## Teardown

Run:

```
./aws/teardown.sh
```

Use the same hosted zone and subdomain prefix you used during deploy.

## Notes

- TLS is terminated at the NLB. Traefik only listens on HTTP internally.
- The ECS task uses localhost (`127.0.0.1`) to connect between containers.
- RDS is a single shared database for both OpenWebUI and LiteLLM.
- EFS is required for persistence (uploads, vectors, Ollama models).
- IAM policy attached to the task role allows Bedrock `InvokeModel` (adjust as needed).

## Files

- `aws/deploy.sh` - Terraform apply + ECR image push + ECS refresh
- `aws/teardown.sh` - Terraform destroy
- `aws/terraform/` - Infrastructure as code
- `aws/traefik/` - Traefik config and Dockerfile (built into ECR)
