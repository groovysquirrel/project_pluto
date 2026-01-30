#!/bin/sh
# =============================================================================
# Dashy Entrypoint Script
# =============================================================================
# This script processes environment variables in the Dashy configuration
# before starting the application.
# =============================================================================

set -e

echo "[Dashy] Processing configuration with environment variables..."

# Set defaults if not provided
export PLUTO_DOMAIN="${PLUTO_DOMAIN:-pluto.local}"
export COGNITO_ACCOUNT_URL="${COGNITO_ACCOUNT_URL:-#}"

# Process the template with envsubst
envsubst < /app/user-data/conf.yml.template > /app/user-data/conf.yml

echo "[Dashy] Configuration processed successfully"
echo "[Dashy] Domain: $PLUTO_DOMAIN"
echo "[Dashy] Cognito URL: $COGNITO_ACCOUNT_URL"

# Start Dashy using the original entrypoint
exec node /app/server.js
