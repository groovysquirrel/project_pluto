#!/bin/bash

# ==============================================================================
# PROJECT PLUTO MIGRATION SCRIPT
# ==============================================================================
# This script handles backing up and restoring Project Pluto data in a portable
# format that works across Docker and cloud deployments.
#
# Backup format (pluto_backup_YYYYMMDD_HHMMSS.tar.gz):
#   - manifest.json
#   - postgres/*.sql (logical dumps)
#   - volumes/* (volume contents)
#
# Usage:
#   ./migrate.sh backup   -> Creates pluto_backup_[date].tar.gz
#   ./migrate.sh restore  -> Restores from pluto_backup.tar.gz
# ==============================================================================

# Source shared helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common/scripts/helpers.sh"

REPO_ROOT="$(get_repo_root)"

# Load environment variables (for Docker Compose interpolation)
load_env "${REPO_ROOT}/.env"

BACKUP_FILE="pluto_backup.tar.gz"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="pluto_backup_${TIMESTAMP}.tar.gz"

# Volumes to include in the portable backup
VOLUME_NAMES=(
    "openwebui-data"
    "n8n-data"
    "qdrant-data"
    "pgadmin-data"
    "ollama-data"
    "fastmcp-data"
)

# Databases to dump (shared Postgres)
DB_NAMES=(
    "openwebui"
    "litellm"
    "n8n"
)

# ------------------------------------------------------------------------------
# HELPERS
# ------------------------------------------------------------------------------

compose() {
    if [ -f "${REPO_ROOT}/docker/docker-compose.yml" ]; then
        docker compose -f "${REPO_ROOT}/docker/docker-compose.yml" "$@"
    else
        docker compose "$@"
    fi
}

check_docker() {
    require_command docker "Docker is required but not installed"
}

check_postgres_env() {
    if [ -z "${POSTGRES_PASSWORD}" ]; then
        print_error "POSTGRES_PASSWORD is not set. Please configure .env."
    fi

    if [ -z "${POSTGRES_USER}" ]; then
        POSTGRES_USER="pluto"
    fi
}

wait_for_postgres() {
    local retries=30
    local sleep_time=2

    while [ $retries -gt 0 ]; do
        if compose exec -T postgres sh -lc "PGPASSWORD='${POSTGRES_PASSWORD}' pg_isready -U '${POSTGRES_USER}'" >/dev/null 2>&1; then
            return 0
        fi
        retries=$((retries - 1))
        sleep $sleep_time
    done

    print_error "Postgres did not become ready in time."
}

# ------------------------------------------------------------------------------
# BACKUP FUNCTION
# ------------------------------------------------------------------------------

backup_postgres() {
    local output_dir="$1"
    local dumped_dbs=()

    print_info "Ensuring Postgres is running..."
    compose up -d postgres
    wait_for_postgres

    mkdir -p "$output_dir"

    for db in "${DB_NAMES[@]}"; do
        local exists
        exists=$(compose exec -T postgres sh -lc "PGPASSWORD='${POSTGRES_PASSWORD}' psql -U '${POSTGRES_USER}' -At -c \"select 1 from pg_database where datname='${db}'\"" | tr -d '\r')
        if [ "$exists" = "1" ]; then
            print_info "Dumping database: ${db}"
            compose exec -T postgres sh -lc "PGPASSWORD='${POSTGRES_PASSWORD}' pg_dump -U '${POSTGRES_USER}' -d '${db}' --clean --if-exists --no-owner --no-privileges" > "${output_dir}/${db}.sql"
            dumped_dbs+=("$db")
        else
            print_warning "Database not found, skipping: ${db}"
        fi
    done

    printf '%s\n' "${dumped_dbs[@]}"
}

backup_volumes() {
    local output_dir="$1"
    local mount_args=""
    local backed_up_volumes=()

    for vol in "${VOLUME_NAMES[@]}"; do
        if docker volume inspect "pluto-${vol}" >/dev/null 2>&1; then
            mount_args+=" -v pluto-${vol}:/backup/${vol}"
            backed_up_volumes+=("$vol")
        else
            print_warning "Volume not found, skipping: pluto-${vol}"
        fi
    done

    if [ -z "$mount_args" ]; then
        print_warning "No volumes found to back up."
        printf '%s\n' "${backed_up_volumes[@]}"
        return 0
    fi

    mkdir -p "$output_dir"

    print_info "Copying volume data..."
    docker run --rm $mount_args -v "${output_dir}:/host" busybox \
        sh -c "tar -cf /host/volumes.tar -C /backup ."

    tar -xf "${output_dir}/volumes.tar" -C "$output_dir"
    rm -f "${output_dir}/volumes.tar"

    printf '%s\n' "${backed_up_volumes[@]}"
}

do_backup() {
    print_header "Starting Backup: ${BACKUP_NAME}"

    check_docker
    check_postgres_env

    TMP_DIR=$(mktemp -d)
    mkdir -p "${TMP_DIR}/postgres" "${TMP_DIR}/volumes"

    # macOS-compatible alternative to mapfile
    DUMPED_DBS=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && DUMPED_DBS+=("$line")
    done < <(backup_postgres "${TMP_DIR}/postgres")

    BACKED_UP_VOLUMES=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && BACKED_UP_VOLUMES+=("$line")
    done < <(backup_volumes "${TMP_DIR}/volumes")

    print_info "Writing manifest"
    PLUTO_DUMPED_DBS="$(printf '%s\n' "${DUMPED_DBS[@]}")" \
    PLUTO_BACKED_UP_VOLUMES="$(printf '%s\n' "${BACKED_UP_VOLUMES[@]}")" \
    python3 - <<'PY' > "${TMP_DIR}/manifest.json"
import json
import os
import time

def parse_list(value):
    if not value:
        return []
    return [item for item in value.split("\n") if item]

manifest = {
    "format_version": 1,
    "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "project": "pluto",
    "postgres_dumps": parse_list(os.environ.get("PLUTO_DUMPED_DBS", "")),
    "volumes": parse_list(os.environ.get("PLUTO_BACKED_UP_VOLUMES", "")),
}

print(json.dumps(manifest, indent=2))
PY

    tar -czf "${BACKUP_NAME}" -C "${TMP_DIR}" .

    rm -rf "${TMP_DIR}"

    print_success "Backup created: ${BACKUP_NAME}"
    echo ""
    echo "To migrate to a new server:"
    echo "1. Copy this file to new server: scp ${BACKUP_NAME} user@host:~/"
    echo "2. Clone this repo on the new server"
    echo "3. Run: ./pluto.sh restore docker ${BACKUP_NAME}"
}

# ------------------------------------------------------------------------------
# RESTORE FUNCTION
# ------------------------------------------------------------------------------

read_manifest_list() {
    local manifest="$1"
    local key="$2"

    python3 - <<PY
import json
import sys

with open("${manifest}") as handle:
    data = json.load(handle)

items = data.get("${key}", [])
for item in items:
    print(item)
PY
}

restore_volumes() {
    local volume_dir="$1"
    shift
    local volumes=("$@")

    if [ ! -d "$volume_dir" ]; then
        print_warning "Volume directory not found in backup: ${volume_dir}"
        return 0
    fi

    local mount_args=""
    for vol in "${volumes[@]}"; do
        docker volume create --label com.docker.compose.project=pluto "pluto-${vol}" >/dev/null
        mount_args+=" -v pluto-${vol}:/restore/${vol}"
    done

    if [ -z "$mount_args" ]; then
        print_warning "No volumes selected for restore."
        return 0
    fi

    print_info "Restoring volume data..."
    docker run --rm $mount_args -v "${volume_dir}:/host/volumes:ro" busybox \
        sh -c "mkdir -p /restore && tar -cf - -C /host/volumes . | tar -xf - -C /restore"
}

restore_postgres() {
    local postgres_dir="$1"
    shift
    local dbs=("$@")

    if [ ! -d "$postgres_dir" ]; then
        print_warning "Postgres dumps not found in backup. Skipping database restore."
        return 0
    fi

    print_info "Starting Postgres container..."
    compose up -d postgres
    wait_for_postgres

    for db in "${dbs[@]}"; do
        local dump_file="${postgres_dir}/${db}.sql"
        if [ ! -f "$dump_file" ]; then
            print_warning "Dump file missing, skipping: ${db}"
            continue
        fi

        # Check if database exists
        local exists
        exists=$(docker exec infra-postgres psql -U "${POSTGRES_USER}" -At -c "SELECT 1 FROM pg_database WHERE datname='${db}'" 2>/dev/null | tr -d '\r')
        if [ "$exists" != "1" ]; then
            print_info "Creating database: ${db}"
            docker exec infra-postgres createdb -U "${POSTGRES_USER}" "${db}"
        fi

        print_info "Restoring database: ${db}"
        # Copy dump file into container and restore using psql -f
        # This avoids shell escaping issues with piped stdin
        docker cp "$dump_file" "infra-postgres:/tmp/${db}.sql"
        docker exec infra-postgres psql -U "${POSTGRES_USER}" -d "${db}" -f "/tmp/${db}.sql"
        docker exec infra-postgres rm -f "/tmp/${db}.sql"
    done
}

do_restore() {
    local file_to_restore=${1:-$BACKUP_FILE}
    local services_stopped=false

    print_header "Starting Restore from: ${file_to_restore}"

    if [ ! -f "$file_to_restore" ]; then
        print_error "Backup file not found: ${file_to_restore}"
    fi

    check_docker
    check_postgres_env

    TMP_DIR=$(mktemp -d)
    tar -xzf "$file_to_restore" -C "${TMP_DIR}"

    local manifest="${TMP_DIR}/manifest.json"
    local volume_dir="${TMP_DIR}/volumes"
    local postgres_dir="${TMP_DIR}/postgres"

    local restore_volumes=("${VOLUME_NAMES[@]}")
    local restore_dbs=("${DB_NAMES[@]}")

    if [ -f "$manifest" ]; then
        restore_volumes=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && restore_volumes+=("$line")
        done < <(read_manifest_list "$manifest" "volumes")

        restore_dbs=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && restore_dbs+=("$line")
        done < <(read_manifest_list "$manifest" "postgres_dumps")
    else
        print_warning "Manifest not found. Attempting legacy restore."
        volume_dir="${TMP_DIR}"
    fi

    if [ ${#restore_volumes[@]} -gt 0 ]; then
        if [ "$services_stopped" = false ]; then
            print_info "Stopping containers..."
            compose down
            services_stopped=true
        fi

        print_info "Restoring volume data..."
        restore_volumes "$volume_dir" "${restore_volumes[@]}"
    else
        print_warning "No volumes found to restore."
    fi

    if [ ${#restore_dbs[@]} -gt 0 ]; then
        if [ "$services_stopped" = false ]; then
            print_info "Stopping containers..."
            compose down
            services_stopped=true
        fi

        restore_postgres "$postgres_dir" "${restore_dbs[@]}"
    else
        print_warning "No database dumps found to restore."
    fi

    rm -rf "${TMP_DIR}"

    print_success "Restore complete!"
    echo ""
    echo "You can now run ./pluto.sh deploy docker to start services with restored data."
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
