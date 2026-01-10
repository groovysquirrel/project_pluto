# Project Pluto

**An integrated, containerized AI development platform.**

Project Pluto combines best-in-class AI tools into a single, cohesive local environment. It unifies chat (OpenWebUI), workflows (n8n), LLM routing (LiteLLM), and agentic tools (MCP) under one roof, backed by shared persistence (PostgreSQL/ChromaDB).

## 🚀 Features

*   **Unified AI Portal**: A single landing page accessing all services.
*   **LLM Gateway (LiteLLM)**: Access AWS Bedrock models (Claude 3.5, Llama 3.1) via an OpenAI-compatible API.
*   **Agentic Tools (MCP)**:
    *   **MCPJungle**: Central gateway managing all MCP servers.
    *   **BrowserBase**: Cloud browsing automation for agents (powered by local LiteLLM).
    *   **DuckDuckGo**: Privacy-focused web search.
*   **RAG Ready**: Dedicated **ChromaDB** container for persistent document embeddings.
*   **Robust Management**:
    *   **Portainer**: Visual Docker management.
    *   **pgAdmin**: PostgreSQL database management.
    *   **Chroma Admin**: Vector database inspection.
*   **Production Ready**: Automated scripts for deployment (`deploy.sh`), teardown, and cloud migration (`migrate.sh`).

---

## 🏗️ Architecture

```mermaid
graph TD
    User[User] --> Portal[Web Portal :8080]
    Portal --> OpenWebUI[OpenWebUI :3001]
    Portal --> n8n[n8n Workflows :5678]
    Portal --> Portainer[Portainer :9000]
    
    subgraph Data Layer
        Postgres[(PostgreSQL)]
        Chroma[(ChromaDB)]
    end

    subgraph AI Core
        OpenWebUI --> LiteLLM[LiteLLM Proxy :4000]
        n8n --> LiteLLM
        LiteLLM --> AWS[AWS Bedrock]
        OpenWebUI --> Chroma
    end

    subgraph MCP Ecosystem
        MCPJungle[MCPJungle Gateway :8090]
        OpenWebUI -.-> MCPJungle
        n8n -.-> MCPJungle
        MCPJungle --> DDG[DuckDuckGo MCP]
        MCPJungle --> BrowserBase[BrowserBase MCP]
        BrowserBase --> LiteLLM
    end

    OpenWebUI --> Postgres
    n8n --> Postgres
    LiteLLM --> Postgres
```

---

## 🏁 Getting Started

### Prerequisites
1.  **Docker Desktop**: Installed and running.
2.  **AWS CLI**: Configured with access to Bedrock models.
    ```bash
    aws configure  # Enter Access Key, Secret, and Region (e.g., us-east-1)
    ```

### Quick Deploy
```bash
# 1. Clone repo
git clone <repo-url>
cd project_pluto

# 2. Configure Environment
cp .env.example .env
# Edit .env to add BrowserBase keys (optional) and customize settings

# 3. Deploy
./deploy.sh
```

### Access Points
| Service | URL | Description | Credentials |
|---------|-----|-------------|-------------|
| **Portal** | [localhost:8080](http://localhost:8080) | **Start Here!** Unified navigation. | - |
| **OpenWebUI** | [localhost:3001](http://localhost:3001) | Chat interface & RAG. | Auto-created (admin@pluto.local) |
| **LiteLLM** | [localhost:4000](http://localhost:4000) | LLM Proxy API & UI. | Master Key in `.env` |
| **n8n** | [localhost:5678](http://localhost:5678) | Workflow Automation. | `admin` / `changeme` |
| **MCPJungle** | [localhost:8090](http://localhost:8090) | MCP Gateway. | - |
| **Portainer** | [localhost:9000](http://localhost:9000) | Docker Management. | Set on first login |
| **pgAdmin** | [localhost:5050](http://localhost:5050) | PostgreSQL UI. | `admin@pluto.com` / `changeme` |
| **Chroma Admin**| [localhost:8002](http://localhost:8002) | Vector DB UI. | - |

---

## 🛠️ Management & Maintenance

### Migration (Backup/Restore)
Move your entire environment to a new machine or cloud server.
```bash
# Backup all volumes (Postgres, n8n, RAG, etc.)
./migrate.sh backup

# Restore from file
./migrate.sh restore pluto_backup_YYYYMMDD.tar.gz
```

### Teardown
Stop everything. optionally delete data.
```bash
# Stop containers
./teardown.sh

# Stop AND delete all data (Fresh Start)
./teardown.sh --all
```

---

## 📚 Developed By
Justin St-Maurice
Technical Counselor
AI Engineering and Systems Design
Info-Tech Research Group
