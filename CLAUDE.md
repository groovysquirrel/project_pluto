# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Project Pluto is a self-hosted AI development platform that combines multiple AI tools into a unified environment with multi-cloud deployment support. The platform integrates:

- **OpenWebUI** - Chat interface with RAG capabilities
- **LiteLLM** - OpenAI-compatible API gateway for AWS Bedrock (Claude, Llama, Nova)
- **n8n** - Visual workflow automation
- **FastMCP** - VS Code in browser + Python MCP server for custom AI tools
- **Qdrant** - Vector database for RAG embeddings
- **PostgreSQL** - Shared database with per-service isolation
- **Traefik** - Reverse proxy with TLS termination

## Deployment Commands

### Docker (Local Development)

```bash
# Deploy all services
./pluto.sh deploy docker

# Stop services (keep data)
./pluto.sh teardown docker

# Stop and delete all data
./pluto.sh teardown docker --all

# Create backup
./pluto.sh backup docker

# Restore from backup
./pluto.sh restore docker pluto_backup_YYYYMMDD_HHMMSS.tar.gz
```

### AWS (ECS/Fargate)

```bash
# Deploy to AWS
./pluto.sh deploy aws

# Teardown AWS infrastructure
./pluto.sh teardown aws
```

**Prerequisites for AWS deployment:**
- AWS CLI configured (`aws configure`)
- Terraform >= 1.5.0
- Docker installed and running
- Route53 hosted zone exists
- Copy `aws/.env.example` to `aws/.env` and configure

### Direct Docker Compose

```bash
cd docker

# Start services
docker compose up -d

# View logs
docker compose logs -f

# Stop services
docker compose down
```

## Architecture

### Multi-Environment Structure

The repository supports deployment to multiple environments with shared configuration:

```
project_pluto/
├── pluto.sh              # Universal deployment CLI
├── migrate.sh            # Backup/restore utility
├── docker/               # Local Docker Compose deployment
├── aws/                  # AWS ECS/Fargate (Terraform)
├── azure/                # Azure Container Apps (planned)
├── gcp/                  # GCP Cloud Run (planned)
└── common/               # Shared configs across all environments
    ├── database/         # PostgreSQL init scripts
    ├── litellm/          # LiteLLM model configuration
    └── portal/           # Landing page assets
```

### Service Communication

**Docker Environment:**
- All services communicate via Docker network (`pluto-network`)
- Traefik routes external traffic based on domain names (*.pluto.local)
- Internal DNS via dnsmasq at 172.20.0.53 for *.pluto.local resolution
- Services use domain names internally (e.g., `https://litellm.pluto.local/v1`)

**AWS Environment:**
- All services run as a single ECS Fargate task (sidecar pattern)
- Containers communicate via localhost (127.0.0.1)
- ALB with Cognito authentication handles external traffic
- RDS PostgreSQL for database, EFS for persistent storage

### Database Architecture

PostgreSQL is shared across services with separate databases per service:
- `openwebui` - Chat history, user accounts, settings
- `litellm` - Usage tracking, API keys, model configs
- `n8n` - Workflows, credentials, execution logs

Database initialization happens via `common/database/init-databases.sh` which creates separate databases and grants appropriate permissions.

### LiteLLM Configuration

LiteLLM acts as an OpenAI-compatible proxy to AWS Bedrock models. Configuration is in `common/litellm/config.yaml`:

- **Cross-region inference profiles**: Newer Claude models (3.5+, 3.7, 4.5 Opus) use `us.anthropic.claude-xxx` format for better availability
- **Direct model IDs**: Older models use direct Bedrock ARNs like `anthropic.claude-3-haiku-20240307-v1:0`
- **Embeddings**: Titan embeddings for AWS, Ollama embeddings for local

All applications (OpenWebUI, n8n) communicate with LiteLLM instead of directly calling Bedrock.

### TLS/HTTPS Architecture

**Docker:**
- Self-signed CA certificate generated at `docker/traefik/certs/pluto-ca.crt`
- Traefik generates individual certificates for each subdomain
- CA certificate mounted into containers that make HTTPS calls (n8n, FastMCP)
- Containers set `NODE_EXTRA_CA_CERTS` or update CA trust store

**AWS:**
- ACM manages TLS certificates for public domain
- ALB terminates TLS and routes to containers over HTTP

### RAG (Retrieval Augmented Generation)

**Docker:**
- OpenWebUI → Qdrant (vectors) + Ollama (embeddings)
- Embedding model: `nomic-embed-text` via Ollama

**AWS (Future):**
- OpenWebUI → OpenSearch Serverless (vectors) + Bedrock (embeddings)
- Embedding model: `amazon.titan-embed-text-v2:0` via LiteLLM

## Environment Configuration

The `.env` file contains critical secrets and must be properly configured:

**Essential variables:**
```bash
# PostgreSQL
POSTGRES_PASSWORD=<required>
POSTGRES_USER=pluto

# LiteLLM
LITELLM_MASTER_KEY=<required>

# OpenWebUI
WEBUI_SECRET_KEY=<required>

# n8n
N8N_ENCRYPTION_KEY=<required>
ADMIN_PASSWORD=<required>

# Domain (Docker)
PLUTO_DOMAIN=pluto.local
```

**IMPORTANT**: Encryption keys (N8N_ENCRYPTION_KEY, WEBUI_SECRET_KEY) must remain consistent across backups/restores or encrypted data will be lost.

## Testing and Validation

There are no automated test suites. Validation is manual:

1. Deploy the stack
2. Access each service via its URL
3. Test service integrations (e.g., OpenWebUI → LiteLLM → Bedrock)
4. Verify RAG functionality with document upload
5. Test backup/restore process

## Common Development Tasks

### Adding a New LLM Model

Edit `common/litellm/config.yaml` and add to `model_list`:

```yaml
- model_name: my-new-model
  litellm_params:
    model: bedrock/us.anthropic.claude-new-model
    aws_region_name: us-east-1
```

Restart LiteLLM:
```bash
docker compose restart litellm
```

### Modifying Traefik Routes

Routes are defined via Docker labels in `docker/docker-compose.yml`. To add a new service:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.myservice.rule=Host(`myservice.${PLUTO_DOMAIN:-pluto.local}`)"
  - "traefik.http.routers.myservice.entrypoints=websecure"
  - "traefik.http.routers.myservice.tls=true"
  - "traefik.http.services.myservice.loadbalancer.server.port=8080"
```

### Accessing PostgreSQL Directly

```bash
# Via psql
docker exec -it infra-postgres psql -U pluto -d openwebui

# Via pgAdmin
# Visit https://pgadmin.pluto.local:8443
```

### Viewing Container Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f openwebui

# Last 100 lines
docker compose logs --tail 100 litellm
```

### Modifying the Portal Landing Page

Edit files in `common/portal/html/`:
- `index.html` - Structure and content
- `style.css` - Styling
- `app.js` - Dynamic behavior
- `env.js` - Environment-specific config (generated at deploy time)

Changes take effect immediately (nginx serves static files).

## AWS-Specific Guidance

### Terraform Structure

Terraform configuration is in `aws/terraform/`:
- `main.tf` - VPC, ECS, ALB, RDS, EFS, ECR
- `cognito.tf` - User pool and ALB authentication
- `variables.tf` - Input variables
- `outputs.tf` - Output values (URLs, resource IDs)

### Cognito SSO Authentication

All services are protected by AWS Cognito via ALB listener rules. The authentication architecture is:

**OpenWebUI & n8n**: Full Cognito authentication on all paths
- Users must log in via Cognito before accessing any part of the application
- ALB injects authentication headers (`x-amzn-oidc-*`) that applications can read

**LiteLLM**: Split authentication by path
- **API paths** (`/v1/*`, `/health/*`, `/chat/*`): No Cognito, uses LiteLLM API key authentication
  - Allows OpenWebUI and n8n to call the API programmatically
  - Clients authenticate with `Authorization: Bearer sk-<api-key>` header
- **Web UI paths** (`/ui`, `/` etc.): Protected by Cognito
  - Human users log in via Cognito to access the LiteLLM admin interface
  - Configured in `main.tf` via two ALB listener rules (priority 200 & 201)

**Why this split?**
- Services calling LiteLLM's API can't handle browser-based OAuth flows
- The web UI needs human authentication for admin access
- This provides both security and functionality

### Deploying Infrastructure Changes

```bash
cd aws/terraform
terraform plan   # Preview changes
terraform apply  # Apply changes
```

### Pushing Updated Container Images

The `aws/deploy.sh` script handles:
1. Building images locally
2. Tagging for ECR
3. Pushing to ECR
4. Forcing ECS service update

To update a single service image, manually:
```bash
# Build and push
docker build -t <account>.dkr.ecr.us-east-1.amazonaws.com/pluto-openwebui:latest .
docker push <account>.dkr.ecr.us-east-1.amazonaws.com/pluto-openwebui:latest

# Force ECS update
aws ecs update-service --cluster pluto-cluster --service pluto-service --force-new-deployment
```

### Lambda Functions

Lambda functions are in `aws/lambda/`:
- `cognito_presignup/` - Auto-approve Cognito signups

Lambda code is managed via Terraform (inline or ZIP archive).

## Backup/Restore Process

The `migrate.sh` script creates portable backups containing:
- PostgreSQL logical dumps (per database)
- Docker volume contents
- `.env` file (encryption keys)
- `manifest.json` (metadata)

**Backup format:** `pluto_backup_YYYYMMDD_HHMMSS.tar.gz`

**Critical**: The backup includes encryption keys. Restoring without the original keys will result in data loss (n8n credentials, OpenWebUI sessions).

## File Organization Conventions

- **Deployment scripts** are in environment-specific folders (`docker/`, `aws/`)
- **Shared configuration** is in `common/` and referenced by all environments
- **Service-specific builds** (Dockerfiles) are in environment folders (e.g., `docker/fastmcp/`)
- **Documentation** is in README.md files per directory

## Key Design Decisions

1. **Unified domain-based routing**: Services use the same domains internally and externally (via Traefik) rather than container names. This provides consistency and allows services to call each other using HTTPS.

2. **Shared PostgreSQL**: One database instance with separate databases per service. This reduces resource usage while maintaining isolation.

3. **LiteLLM as the single LLM gateway**: All services route through LiteLLM rather than calling providers directly. This centralizes usage tracking and simplifies provider switching.

4. **Sidecar pattern on AWS**: All services run in one ECS task for simplified networking (localhost communication). Trade-off: less granular scaling.

5. **Environment variable inheritance**: AWS credentials and secrets flow from host → container via environment variables and mounted volumes rather than being hardcoded.
