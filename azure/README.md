# Azure Deployment (Future)

This directory will contain Azure-specific deployment configuration.

## Planned Architecture

```
Internet → Azure Front Door (TLS) → Container Apps → Services
                                         ↓
                               Azure Database for PostgreSQL
                               Azure Files (persistent storage)
```

## Key Components

| Component | Azure Service |
|-----------|---------------|
| Container Orchestration | Azure Container Apps |
| Load Balancer | Azure Front Door |
| Database | Azure Database for PostgreSQL (Flexible) |
| Persistent Storage | Azure Files |
| Secrets | Azure Key Vault |
| DNS | Azure DNS |
| WAF | Azure WAF |

## Files (To Be Created)

- `deploy.sh` - Azure deployment script
- `teardown.sh` - Azure cleanup script
- `terraform/` or `bicep/` - Infrastructure as Code

## Prerequisites

- Azure CLI configured (`az login`)
- Terraform or Bicep installed
- Resource group created
