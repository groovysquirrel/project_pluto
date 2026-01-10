#!/bin/bash

# ==============================================================================
# PROJECT PLUTO MIGRATION SCRIPT
# ==============================================================================
# This script handles backing up and restoring all localized data (Docker volumes).
# Use this to move your entire environment from local to cloud (AWS/GCP/Azure).
#
# Usage:
#   ./migrate.sh backup   -> Creates pluto_backup_[date].tar.gz
#   ./migrate.sh restore  -> Restores from pluto_backup.tar.gz
# ==============================================================================

# Source shared helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common/scripts/helpers.sh"

# Load environment variables (for Docker Compose interpolation)
load_env "${SCRIPT_DIR}/.env"

BACKUP_FILE="pluto_backup.tar.gz"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="pluto_backup_${TIMESTAMP}.tar.gz"

# List of volumes to backup/restore
VOLUMES=(
    "openwebui-data"
    "n8n-data"
    "chromadb-data"
    "postgres-data"
    "pgadmin-data"
    "portainer-data"


)

# ------------------------------------------------------------------------------
# HELPERS
# ------------------------------------------------------------------------------
print_header() {
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  $1${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed or not in PATH"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# BACKUP FUNCTION
# ------------------------------------------------------------------------------
do_backup() {
    print_header "Starting Backup: ${BACKUP_NAME}"

    check_docker

    # Stop containers to ensure data consistency
    echo "Stopping containers..."
    if [ -f docker/docker-compose.yml ]; then
        docker compose -f docker/docker-compose.yml down
    else
        docker compose down
    fi

    # 2. Create a temporary container to mount volumes and tar them
    echo "Backing up volumes..."
    
    # We mount each volume to /backup/volume_name
    MOUNT_ARGS=""
    for vol in "${VOLUMES[@]}"; do
        MOUNT_ARGS="$MOUNT_ARGS -v pluto-${vol}:/backup/${vol}"
    done

    # Run busybox to tar contents
    # We tar the /backup directory contents
    docker run --rm $MOUNT_ARGS -v $(pwd):/host busybox \
        tar -czf /host/${BACKUP_NAME} -C /backup .

    if [ $? -eq 0 ]; then
        print_success "Backup created: ${BACKUP_NAME}"
        echo ""
        echo "To migrate to a new server:"
        echo "1. Copy this file to new server: scp ${BACKUP_NAME} user@host:~/"
        echo "2. Clone this repo on the new server"
        echo "3. Run: ./migrate.sh restore ${BACKUP_NAME}"
    else
        print_error "Backup failed!"
        exit 1
    fi
    
    # Optional: Restart services
    echo ""
    read -p "Restart services now? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ./deploy.sh
    fi
}

# ------------------------------------------------------------------------------
# RESTORE FUNCTION
# ------------------------------------------------------------------------------
do_restore() {
    FILE_TO_RESTORE=${1:-$BACKUP_FILE}

    print_header "Starting Restore from: ${FILE_TO_RESTORE}"

    if [ ! -f "$FILE_TO_RESTORE" ]; then
        print_error "Backup file not found: ${FILE_TO_RESTORE}"
        exit 1
    fi

    check_docker

    # 1. Stop containers
    echo "Stopping containers..."
    if [ -f docker/docker-compose.yml ]; then
        docker compose -f docker/docker-compose.yml down
    else
        docker compose down
    fi

    # 2. Check if volumes exist, warn user
    echo "Checking volumes..."
    EXISTING_DATA=false
    for vol in "${VOLUMES[@]}"; do
        if docker volume inspect pluto-${vol} >/dev/null 2>&1; then
            EXISTING_DATA=true
            break
        fi
    done

    if [ "$EXISTING_DATA" = true ]; then
        echo -e "${RED}WARNING: Existing data volumes found!${NC}"
        echo "Restoring will OVERWRITE existing data."
        read -p "Are you sure you want to continue? (y/N) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Restore cancelled."
            exit 1
        fi
    fi

    # 3. Restore data
    echo "Restoring volumes..."
    
    # Ensure volumes exist (create them if they don't)
    for vol in "${VOLUMES[@]}"; do
        docker volume create --label com.docker.compose.project=pluto pluto-${vol} >/dev/null
    done

    # Mount volumes and untar
    MOUNT_ARGS=""
    for vol in "${VOLUMES[@]}"; do
        MOUNT_ARGS="$MOUNT_ARGS -v pluto-${vol}:/backup/${vol}"
    done

    # Run busybox to untar
    docker run --rm $MOUNT_ARGS -v $(pwd):/host busybox \
        tar -xzf /host/${FILE_TO_RESTORE} -C /backup

    if [ $? -eq 0 ]; then
        print_success "Restore complete!"
        echo ""
        echo "You can now run ./deploy.sh to start services with restored data."
    else
        print_error "Restore failed!"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------
case "$1" in
    backup)
        do_backup
        ;;
    restore)
        do_restore "$2"
        ;;
    *)
        echo "Usage: $0 {backup|restore [filename]}"
        exit 1
        ;;
esac
