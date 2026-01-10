#!/bin/bash
# ==============================================================================
# PROJECT PLUTO - Universal Deployment Entrypoint
# ==============================================================================
#
# This script routes deployment commands to the appropriate environment.
#
# USAGE:
#   ./pluto.sh deploy docker     # Deploy locally with Docker Compose
#   ./pluto.sh teardown docker   # Tear down local Docker deployment
#   ./pluto.sh deploy aws        # Deploy to AWS (future)
#   ./pluto.sh deploy azure      # Deploy to Azure (future)
#   ./pluto.sh deploy gcp        # Deploy to GCP (future)
#
# ==============================================================================

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# HELP
# ------------------------------------------------------------------------------
show_help() {
    echo ""
    echo -e "${CYAN}Project Pluto - Multi-Environment Deployment${NC}"
    echo ""
    echo "Usage: ./pluto.sh <action> <environment> [options]"
    echo ""
    echo "Actions:"
    echo "  deploy     Deploy Project Pluto"
    echo "  teardown   Tear down Project Pluto"
    echo ""
    echo "Environments:"
    echo "  docker     Local Docker Compose deployment"
    echo "  aws        AWS ECS/Fargate deployment (coming soon)"
    echo "  azure      Azure Container Apps deployment (coming soon)"
    echo "  gcp        GCP Cloud Run deployment (coming soon)"
    echo ""
    echo "Examples:"
    echo "  ./pluto.sh deploy docker       # Start local environment"
    echo "  ./pluto.sh teardown docker     # Stop local environment"
    echo "  ./pluto.sh teardown docker --all  # Stop and delete all data"
    echo ""
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

ACTION="${1:-}"
TARGET="${2:-}"
shift 2 2>/dev/null || true

# Validate arguments
if [ -z "$ACTION" ] || [ -z "$TARGET" ]; then
    show_help
    exit 1
fi

case "$TARGET" in
    docker)
        case "$ACTION" in
            deploy)
                exec "$SCRIPT_DIR/docker/deploy.sh" "$@"
                ;;
            teardown)
                exec "$SCRIPT_DIR/docker/teardown.sh" "$@"
                ;;
            *)
                echo -e "${RED}Unknown action: $ACTION${NC}"
                echo "Valid actions: deploy, teardown"
                exit 1
                ;;
        esac
        ;;
    aws)
        if [ -f "$SCRIPT_DIR/aws/deploy.sh" ]; then
            exec "$SCRIPT_DIR/aws/$ACTION.sh" "$@"
        else
            echo -e "${YELLOW}AWS deployment not yet implemented.${NC}"
            echo "See aws/README.md for planned architecture."
            exit 1
        fi
        ;;
    azure)
        if [ -f "$SCRIPT_DIR/azure/deploy.sh" ]; then
            exec "$SCRIPT_DIR/azure/$ACTION.sh" "$@"
        else
            echo -e "${YELLOW}Azure deployment not yet implemented.${NC}"
            echo "See azure/README.md for planned architecture."
            exit 1
        fi
        ;;
    gcp)
        if [ -f "$SCRIPT_DIR/gcp/deploy.sh" ]; then
            exec "$SCRIPT_DIR/gcp/$ACTION.sh" "$@"
        else
            echo -e "${YELLOW}GCP deployment not yet implemented.${NC}"
            echo "See gcp/README.md for planned architecture."
            exit 1
        fi
        ;;
    *)
        echo -e "${RED}Unknown environment: $TARGET${NC}"
        echo "Valid environments: docker, aws, azure, gcp"
        exit 1
        ;;
esac
