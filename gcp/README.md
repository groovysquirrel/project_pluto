# GCP Deployment (Future)

This directory will contain GCP-specific deployment configuration.

## Planned Architecture

```
Internet → Cloud Load Balancer (TLS) → Cloud Run → Services
                                           ↓
                                     Cloud SQL (PostgreSQL)
                                     Filestore (persistent storage)
```

## Key Components

| Component | GCP Service |
|-----------|-------------|
| Container Orchestration | Cloud Run |
| Load Balancer | Cloud Load Balancer |
| Database | Cloud SQL for PostgreSQL |
| Persistent Storage | Filestore |
| Secrets | Secret Manager |
| DNS | Cloud DNS |
| WAF | Cloud Armor |

## Files (To Be Created)

- `deploy.sh` - GCP deployment script
- `teardown.sh` - GCP cleanup script
- `terraform/` - Infrastructure as Code

## Prerequisites

- gcloud CLI configured (`gcloud auth login`)
- Terraform installed
- Project created and billing enabled
