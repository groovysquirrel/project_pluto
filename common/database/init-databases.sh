#!/bin/bash
# ==============================================================================
# PostgreSQL Initialization Script
# ==============================================================================
# This script runs when PostgreSQL starts for the first time.
# It creates separate databases for each service to avoid table conflicts.
# ==============================================================================

set -e

echo "Creating additional databases for Project Pluto services..."

# Create database for n8n (workflow automation)
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE n8n;
    GRANT ALL PRIVILEGES ON DATABASE n8n TO $POSTGRES_USER;
EOSQL
echo "Created database: n8n"

# Create database for OpenWebUI (chat interface)
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE openwebui;
    GRANT ALL PRIVILEGES ON DATABASE openwebui TO $POSTGRES_USER;
EOSQL
echo "Created database: openwebui"

# Create database for LiteLLM (LLM proxy)
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE litellm;
    GRANT ALL PRIVILEGES ON DATABASE litellm TO $POSTGRES_USER;
EOSQL
echo "Created database: litellm"

echo "All databases created successfully!"
