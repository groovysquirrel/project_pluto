#!/bin/bash
# ==============================================================================
# PROJECT PLUTO - Shared Helper Functions
# ==============================================================================
# This file contains helper functions used across all deployment environments.
# Source this file in deploy.sh / teardown.sh scripts.
#
# Usage:
#   source "$(dirname "$0")/../common/scripts/helpers.sh"
# ==============================================================================

# ------------------------------------------------------------------------------
# COLORS
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color (reset)

# ------------------------------------------------------------------------------
# PRINT FUNCTIONS
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

print_error() {
    echo -e "${RED}✗ ERROR: $1${NC}"
    exit 1
}

print_error_no_exit() {
    echo -e "${RED}✗ ERROR: $1${NC}"
}

# ------------------------------------------------------------------------------
# ENVIRONMENT HELPERS
# ------------------------------------------------------------------------------

# Load environment variables from .env file
# Usage: load_env [path_to_env_file]
load_env() {
    local env_file="${1:-.env}"
    if [ -f "$env_file" ]; then
        set -a
        source "$env_file"
        set +a
        return 0
    else
        return 1
    fi
}

# Generate a secure random secret
# Usage: generate_secret
generate_secret() {
    openssl rand -base64 32 | tr -d '\n'
}

# Check if a command exists
# Usage: require_command docker "Please install Docker"
require_command() {
    local cmd="$1"
    local msg="${2:-$cmd is required but not installed}"
    if ! command -v "$cmd" &> /dev/null; then
        print_error "$msg"
    fi
}

# Get the repo root directory (parent of common/)
get_repo_root() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    # Navigate up to find repo root (contains common/ directory)
    local current="$script_dir"
    while [ "$current" != "/" ]; do
        if [ -d "$current/common" ]; then
            echo "$current"
            return 0
        fi
        current="$(dirname "$current")"
    done
    echo "$script_dir"
}
