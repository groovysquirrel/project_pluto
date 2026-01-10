#!/bin/bash

# ==============================================================================
# PROJECT PLUTO - Teardown Script
# ==============================================================================
#
# This script stops and removes all Project Pluto containers, networks,
# and optionally volumes (data). Use this for:
#   - Testing a fresh deployment
#   - Cleaning up before uninstalling
#   - Resetting everything to start over
#
# USAGE:
#   ./teardown.sh           # Stop containers, keep data
#   ./teardown.sh --all     # Stop containers AND delete all data
#   ./teardown.sh --help    # Show this help
#
# ==============================================================================

# ------------------------------------------------------------------------------
# SETTINGS
# ------------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ------------------------------------------------------------------------------
# HELPER FUNCTIONS
# ------------------------------------------------------------------------------

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

show_help() {
    echo ""
    echo -e "${CYAN}Project Pluto - Teardown Script${NC}"
    echo ""
    echo "Usage: ./teardown.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (no args)    Stop containers but keep all data (volumes)"
    echo "  --all        Stop containers AND delete all data (volumes)"
    echo "  --help       Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./teardown.sh           # Safe teardown, data preserved"
    echo "  ./teardown.sh --all     # Complete reset, all data deleted"
    echo ""
}

# ------------------------------------------------------------------------------
# PARSE ARGUMENTS
# ------------------------------------------------------------------------------

DELETE_VOLUMES=false

case "$1" in
    --all)
        DELETE_VOLUMES=true
        ;;
    --help|-h)
        show_help
        exit 0
        ;;
    "")
        # No arguments, default behavior
        ;;
    *)
        echo -e "${RED}Unknown option: $1${NC}"
        show_help
        exit 1
        ;;
esac

# ------------------------------------------------------------------------------
# CONFIRMATION FOR DESTRUCTIVE OPERATIONS
# ------------------------------------------------------------------------------

if [ "$DELETE_VOLUMES" = true ]; then
    print_header "⚠️  WARNING: Full Teardown"
    echo ""
    echo -e "${YELLOW}This will DELETE ALL DATA including:${NC}"
    echo "  - PostgreSQL database (all tables, data)"
    echo "  - OpenWebUI chat history and settings"
    echo "  - n8n workflows and credentials"
    echo "  - All container volumes"
    echo ""
    read -p "Are you sure you want to delete all data? (type 'yes' to confirm): " confirm
    
    if [ "$confirm" != "yes" ]; then
        echo ""
        print_info "Cancelled. No changes made."
        exit 0
    fi
    echo ""
fi

# ------------------------------------------------------------------------------
# TEARDOWN
# ------------------------------------------------------------------------------

print_header "Stopping Services"

# Check if any containers are running
if docker compose ps --quiet 2>/dev/null | grep -q .; then
    print_info "Stopping all containers..."
    docker compose down
    print_success "All containers stopped"
else
    print_info "No running containers found"
fi

# Delete volumes if requested
if [ "$DELETE_VOLUMES" = true ]; then
    print_header "Removing Data Volumes"
    
    # Remove named volumes
    VOLUMES=(
        "pluto-postgres-data"
        "pluto-openwebui-data"
        "pluto-n8n-data"
        "pluto-chromadb-data"
        "pluto-pgadmin-data"
        "pluto-portainer-data"
    )
    
    for vol in "${VOLUMES[@]}"; do
        if docker volume inspect "$vol" &>/dev/null; then
            docker volume rm "$vol" &>/dev/null
            print_success "Removed volume: $vol"
        else
            print_info "Volume not found: $vol (already removed)"
        fi
    done
    
    # We DO NOT remove .env anymore as it contains user API keys
fi

# Clean up any dangling resources
print_header "Cleanup"

# Remove the network if it exists
if docker network inspect pluto-network &>/dev/null; then
    docker network rm pluto-network &>/dev/null
    print_success "Removed network: pluto-network"
else
    print_info "Network already removed"
fi

# Show summary
print_header "Teardown Complete"

if [ "$DELETE_VOLUMES" = true ]; then
    echo ""
    echo -e "${GREEN}Full teardown complete!${NC}"
    echo -e "All containers, volumes, and data have been removed."
    echo ""
    echo -e "${CYAN}To deploy fresh:${NC}"
    echo -e "  ${YELLOW}./deploy.sh${NC}"
else
    echo ""
    echo -e "${GREEN}Containers stopped!${NC}"
    echo -e "Your data (volumes) has been preserved."
    echo ""
    echo -e "${CYAN}To restart:${NC}"
    echo -e "  ${YELLOW}./deploy.sh${NC}"
    echo ""
    echo -e "${CYAN}To also delete all data:${NC}"
    echo -e "  ${YELLOW}./teardown.sh --all${NC}"
fi
echo ""
