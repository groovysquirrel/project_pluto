# Project Pluto - Context Dump

**Purpose**: This file contains a technical summary of the Project Pluto environment for use in LLM context windows.

## System Overview
Project Pluto is a local, containerized AI development stack orchestrating multiple services via Docker Compose.
*   **LLM Provider**: AWS Bedrock (via LiteLLM proxy).
*   **Frontend**: OpenWebUI (Chat) and a custom Portal (Navigation).
*   **Automation**: n8n (Workflows) with Postgres persistence.
*   **Vector DB**: Qdrant (RAG).
*   **MCP Tools**: MCP Server Manager for managing MCP servers.
*   **Reverse Proxy**: Traefik for domain-based routing and HTTPS.
*   **DNS Server**: dnsmasq for internal `*.pluto.local` resolution.

## Infrastructure
*   **Network**: `pluto-network` (Bridge).
*   **Database**: Shared `postgres:16-alpine` container.
    *   Databases: `n8n`, `openwebui`, `litellm`.
    *   Hostname: `postgres` (internal).

## Service Manifest
| Service | Domain | Internal Port | Description |
|---------|--------|---------------|-------------|
| **Traefik** | `traefik.pluto.local:8443` | 8080 | Reverse proxy & dashboard. |
| **Portal** | `pluto.local` | 80 | Landing page. |
| **Postgres** | `localhost:5432` | 5432 | Shared DB (direct access). |
| **LiteLLM** | `litellm.pluto.local` | 4000 | OpenAI-compatible Proxy for Bedrock. |
| **OpenWebUI** | `openwebui.pluto.local` | 8080 | Chat Interface & RAG Client. |
| **n8n** | `n8n.pluto.local` | 5678 | Workflow Automation. |
| **Qdrant** | `qdrant.pluto.local:8443` | 6333 | Vector Store. |
| **MCP Manager** | `mcp.pluto.local` | 6543 | MCP Server Management UI. |
| **pgAdmin** | `pgadmin.pluto.local:8443` | 80 | PostgreSQL Admin UI. |

## Key Configuration Files
*   `docker/docker-compose.yml`: Definition of all services, volumes, and networks.
*   `docker/deploy.sh`: Deployment script (checks deps, generates SSL certs, updates /etc/hosts).
*   `.env`: Secrets (AWS keys, DB passwords). **GITIGNORED**.
*   `common/litellm/config.yaml`: Model definitions mapping to Bedrock IDs.
*   `docker/traefik/traefik.yml`: Traefik static configuration.

## Active Context Strings
*   **LiteLLM URL**: `https://litellm.pluto.local` (External) or `http://litellm:4000` (Internal).
*   **Portal URL**: `https://pluto.local`
