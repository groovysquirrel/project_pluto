# Project Pluto - Context Dump

**Purpose**: This file contains a technical summary of the Project Pluto environment for use in LLM context windows.

## System Overview
Project Pluto is a local, containerized AI development stack orchestrating multiple services via Docker Compose.
*   **LLM Provider**: AWS Bedrock (via LiteLLM proxy).
*   **Frontend**: OpenWebUI (Chat) and a custom Nginx Portal (Navigation).
*   **Automation**: n8n (Workflows) with Postgres persistence.
*   **Vector DB**: Qdrant (RAG).
*   **Agents (MCP)**: MCPJungle gateway connecting to DuckDuckGo and BrowserBase servers.
*   **Reverse Proxy**: Traefik for domain-based routing and HTTPS.
*   **DNS Server**: dnsmasq for internal `*.pluto.local` resolution.

## Infrastructure
*   **Network**: `pluto-network` (Bridge).
*   **Database**: Shared `postgres:16-alpine` container.
    *   Databases: `n8n`, `openwebui`, `litellm`, `mcpjungle`.
    *   Hostname: `postgres` (internal).

## Service Manifest
| Service | Domain | Internal Port | Description |
|---------|--------|---------------|-------------|
| **Traefik** | `traefik.pluto.local` | 8080 | Reverse proxy & dashboard. |
| **Portal** | `pluto.local` | 80 | Nginx landing page. |
| **Postgres** | `localhost:5432` | 5432 | Shared DB (direct access). |
| **LiteLLM** | `litellm.pluto.local` | 4000 | OpenAI-compatible Proxy for Bedrock. |
| **OpenWebUI** | `openwebui.pluto.local` | 8080 | Chat Interface & RAG Client. |
| **n8n** | `n8n.pluto.local` | 5678 | Workflow Automation. |
| **Qdrant** | `qdrant.pluto.local:8443` | 6333 | Vector Store (HTTP API + UI via Traefik admin port). |
| **MCPJungle** | `mcp.pluto.local` | 8080 | MCP Gateway. |
| **DuckDuckGo MCP** | `ddg.pluto.local` | 8020 | Web search MCP server. |
| **Portainer** | `portainer.pluto.local` | 9000 | Container Management. |
| **pgAdmin** | `pgadmin.pluto.local` | 80 | PostgreSQL Admin UI. |

## Key Configuration Files
*   `docker-compose.yml`: Definition of all 12+ services, volumes, and networks.
*   `deploy.sh`: bash script. Checks deps, generates SSL certs, updates /etc/hosts, runs `docker compose up`.
*   `.env`: Secrets (AWS keys, DB passwords, API keys). **GITIGNORED**.
*   `litellm/config.yaml`: Model definitions mapping OpenAI names to Bedrock IDs.
*   `traefik/traefik.yml`: Traefik static configuration.
*   `traefik/dynamic/tls.yml`: TLS certificate configuration.

## Recent Architectural Decisions
1.  **Domain-based Routing**: Services accessed via `*.pluto.local` instead of `localhost:<port>`.
2.  **Traefik Reverse Proxy**: Handles routing, HTTPS termination, and service discovery.
3.  **Self-signed SSL**: Certificates generated for `*.pluto.local` on first deploy.
4.  **BrowserBase LLM**: Configured to use local `http://litellm:4000/v1` instead of external OpenAI.
5.  **LiteLLM DB**: `STORE_MODEL_IN_DB=True` enabled to allow dynamic model management via UI.

## Active Context Strings
*   **Master Key**: `sk-pluto-master-key` (Default) or defined in `.env`.
*   **LiteLLM URL**: `https://litellm.pluto.local` (External) or `http://litellm:4000` (Internal).
*   **Portal URL**: `https://pluto.local`
