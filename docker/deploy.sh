#!/bin/bash

# ==============================================================================
# PROJECT PLUTO - Deployment Script
# ==============================================================================
#
# This script sets up and launches Project Pluto with a single command.
# It's designed to be beginner-friendly with lots of helpful output.
#
# WHAT THIS SCRIPT DOES:
#   1. Checks that Docker is installed and running
#   2. Verifies required configuration files exist
#   3. Creates .env from .env.example if needed
#   4. Generates self-signed SSL certificates for *.pluto.local
#   5. Adds *.pluto.local entries to /etc/hosts (requires sudo)
#   6. Starts all the containers
#   7. Shows you how to access everything
#
# HOW TO RUN:
#   chmod +x deploy.sh    # Make the script executable (one time only)
#   ./deploy.sh           # Run the deployment
#
# TO TEAR DOWN (for testing):
#   ./teardown.sh         # Stop containers and optionally delete data
#
# ==============================================================================


# ------------------------------------------------------------------------------
# SETTINGS
# ------------------------------------------------------------------------------

# Colors for pretty output (makes the terminal output easier to read)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color (reset)

# Get the directory where this script is located
# This ensures the script works no matter where you run it from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

# ------------------------------------------------------------------------------
# HELPER FUNCTIONS
# ------------------------------------------------------------------------------

# Print a section header
print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

# Print a success message
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Print an info message
print_info() {
    echo -e "${CYAN}ℹ $1${NC}"
}

# Print a warning message
print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Print an error message and exit
print_error() {
    echo -e "${RED}✗ ERROR: $1${NC}"
    exit 1
}

# ------------------------------------------------------------------------------
# PLUTO DOMAIN SETUP FUNCTIONS
# ------------------------------------------------------------------------------

# Domain is loaded from .env (set in Step 3), defaults to pluto.local
# This function generates the list of all PUBLIC subdomains dynamically
# Internal services (ollama, dnsmasq) are NOT included as they
# are only accessible within the Docker network
get_pluto_domains() {
    local domain="${PLUTO_DOMAIN:-pluto.local}"
    echo "$domain"
    echo "openwebui.$domain"
    echo "n8n.$domain"
    echo "litellm.$domain"
    echo "pgadmin.$domain"
    echo "qdrant.$domain"
    echo "ddg.$domain"
    echo "traefik.$domain"
}

# Generate self-signed SSL certificates for the configured domain
generate_ssl_certs() {
    local domain="${PLUTO_DOMAIN:-pluto.local}"
    local CERT_DIR="${SCRIPT_DIR}/traefik/certs"
    local CERT_FILE="${CERT_DIR}/${domain}.crt"
    local KEY_FILE="${CERT_DIR}/${domain}.key"
    
    # Skip if certificates already exist
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        print_info "SSL certificates already exist for ${domain}"
        return 0
    fi
    
    print_info "Generating self-signed SSL certificates for *.${domain}..."
    
    # Ensure directory exists
    mkdir -p "$CERT_DIR"
    
    # Generate certificate with SAN (Subject Alternative Names) for all domains
    # Using OpenSSL to create a certificate valid for 365 days
    # SECURITY: Using 4096-bit RSA for stronger encryption
    openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -subj "/CN=*.${domain}/O=Project Pluto/C=US" \
        -addext "subjectAltName=DNS:${domain},DNS:*.${domain}" \
        2>/dev/null
    
    if [ $? -eq 0 ]; then
        print_success "SSL certificates generated"
        print_info "Certificate: $CERT_FILE"
        print_info "Private key: $KEY_FILE"
    else
        print_warning "Could not generate SSL certificates"
        print_info "HTTPS may not work correctly"
    fi
}

# Install CA certificate to macOS keychain for Chrome trust
install_ca_to_keychain() {
    local domain="${PLUTO_DOMAIN:-pluto.local}"
    local CA_CERT="${SCRIPT_DIR}/traefik/certs/pluto-ca.crt"
    
    # Only run on macOS
    if [[ "$OSTYPE" != "darwin"* ]]; then
        print_info "Skipping keychain installation (not macOS)"
        return 0
    fi
    
    # Check if CA certificate exists
    if [ ! -f "$CA_CERT" ]; then
        print_warning "CA certificate not found, skipping keychain installation"
        return 1
    fi
    
    # Check if already installed in System keychain
    if security find-certificate -c "Project Pluto CA" /Library/Keychains/System.keychain &>/dev/null; then
        print_info "CA certificate already trusted in System keychain"
        return 0
    fi
    
    print_info "Installing CA certificate to System keychain..."
    print_warning "This requires sudo access (so Chrome trusts the certificate)"
    
    # Add to System keychain and trust for SSL
    # -d = add to admin cert store
    # -r trustRoot = trust as root CA
    # -k = keychain to add to
    sudo security add-trusted-cert -d -r trustRoot \
        -k /Library/Keychains/System.keychain \
        "$CA_CERT"
    
    if [ $? -eq 0 ]; then
        print_success "CA certificate installed and trusted!"
        print_info "Chrome will now trust *.${domain} certificates (may need restart)"
    else
        print_warning "Could not install CA certificate"
        print_info "You can manually add it via Keychain Access app:"
        print_info "  1. Open Keychain Access"
        print_info "  2. File → Import Items → Select traefik/certs/pluto-ca.crt"
        print_info "  3. Double-click the certificate → Trust → Always Trust"
    fi
}

# Add domain entries to /etc/hosts (only for local domains)
setup_hosts_file() {
    local domain="${PLUTO_DOMAIN:-pluto.local}"
    local HOSTS_MARKER="# Project Pluto domains (${domain})"
    local HOSTS_END_MARKER="# End Project Pluto domains"
    
    # Skip for non-.local domains (assumes DNS is handled externally)
    if [[ ! "$domain" == *.local ]]; then
        print_info "Domain ${domain} is not a .local domain - skipping /etc/hosts setup"
        print_info "Make sure your DNS is configured to point *.${domain} to this server"
        return 0
    fi
    
    # Remove existing block so we can refresh entries when domains change
    if grep -q "$HOSTS_MARKER" /etc/hosts 2>/dev/null; then
        print_info "Refreshing hosts entries for ${domain}"
        sudo awk -v start="$HOSTS_MARKER" -v end="$HOSTS_END_MARKER" '
            $0 == start {skip=1; next}
            $0 == end {skip=0; next}
            !skip {print}
        ' /etc/hosts | sudo tee /etc/hosts >/dev/null
    fi
    
    print_info "Adding *.${domain} domains to /etc/hosts..."
    print_warning "This requires sudo access"
    
    # Build the hosts entries dynamically
    local HOSTS_ENTRIES="\n${HOSTS_MARKER}\n"
    while IFS= read -r subdomain; do
        HOSTS_ENTRIES+="127.0.0.1   ${subdomain}\n"
    done < <(get_pluto_domains)
    HOSTS_ENTRIES+="${HOSTS_END_MARKER}\n"
    
    # Add to /etc/hosts
    echo -e "$HOSTS_ENTRIES" | sudo tee -a /etc/hosts > /dev/null
    
    if [ $? -eq 0 ]; then
        print_success "Hosts file updated for ${domain}"
    else
        print_error "Could not update /etc/hosts. Please add entries manually."
    fi
}

# ------------------------------------------------------------------------------
# STEP 1: CHECK PREREQUISITES
# ------------------------------------------------------------------------------

print_header "STEP 1: Checking Prerequisites"

# Check if Docker is installed
# 'command -v' checks if a command exists on your system
if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed!

    Please install Docker Desktop from:
    https://www.docker.com/products/docker-desktop

    After installing:
    1. Open Docker Desktop
    2. Wait for it to start (you'll see a whale icon in your menu bar)
    3. Run this script again"
fi
print_success "Docker is installed"

# Check if Docker daemon is running
# We try to get Docker info - if it fails, Docker isn't running
if ! docker info &> /dev/null; then
    print_error "Docker is not running!

    Please start Docker Desktop:
    1. Open Docker Desktop application
    2. Wait for it to fully start (the whale icon should stop animating)
    3. Run this script again"
fi
print_success "Docker is running"

# Check if docker compose is available
# Modern Docker includes 'docker compose' as a subcommand
if ! docker compose version &> /dev/null; then
    print_error "Docker Compose is not available!

    If you have Docker Desktop, this should be included.
    Try updating Docker Desktop to the latest version."
fi
print_success "Docker Compose is available"

# ------------------------------------------------------------------------------
# STEP 2: CHECK REQUIRED FILES
# ------------------------------------------------------------------------------

print_header "STEP 2: Checking Required Files"

# Check for required configuration files
# These should exist in the repository - if missing, something is wrong
REQUIRED_FILES=(
    "docker-compose.yml"
    "${REPO_ROOT}/.env.example"
    "${REPO_ROOT}/common/litellm/config.yaml"
    "${REPO_ROOT}/common/portal/html/index.html"
    "${REPO_ROOT}/common/portal/nginx.conf"
    "traefik/traefik.yml"
    "traefik/dynamic/tls.yml"
)


MISSING_FILES=()
for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$file" ]; then
        print_success "Found $file"
    else
        MISSING_FILES+=("$file")
        print_warning "Missing $file"
    fi
done

if [ ${#MISSING_FILES[@]} -gt 0 ]; then
    print_error "Required files are missing!
    
    Please make sure you have cloned the complete repository.
    Missing files: ${MISSING_FILES[*]}"
fi

# ------------------------------------------------------------------------------
# STEP 3: CREATE ENVIRONMENT FILE
# ------------------------------------------------------------------------------

print_header "STEP 3: Setting Up Environment"

# Create .env from .env.example if it doesn't exist (at repo root)
if [ ! -f "${REPO_ROOT}/.env" ]; then
    cp "${REPO_ROOT}/.env.example" "${REPO_ROOT}/.env"
    print_success "Created .env from .env.example"
    print_info "You can customize settings by editing .env"
else
    print_info ".env already exists, keeping your existing configuration"
fi

# Load environment variables from .env
if [ -f "${REPO_ROOT}/.env" ]; then
    set -a
    source "${REPO_ROOT}/.env"
    set +a
fi

# ------------------------------------------------------------------------------
# STEP 3.1: GENERATE SECURE SECRETS
# ------------------------------------------------------------------------------
# Automatically generate secure random secrets if placeholder values are detected

generate_secret() {
    openssl rand -base64 32 | tr -d '\n'
}

# Check if secrets need to be generated
SECRETS_UPDATED=false

if grep -q "GENERATE_ME_WITH_OPENSSL" "${REPO_ROOT}/.env" 2>/dev/null; then
    print_info "Generating secure secrets..."
    
    # Generate WEBUI_SECRET_KEY
    if grep -q "WEBUI_SECRET_KEY=GENERATE_ME_WITH_OPENSSL" "${REPO_ROOT}/.env"; then
        NEW_SECRET=$(generate_secret)
        sed -i.bak "s|WEBUI_SECRET_KEY=GENERATE_ME_WITH_OPENSSL|WEBUI_SECRET_KEY=${NEW_SECRET}|g" "${REPO_ROOT}/.env"
        print_success "Generated WEBUI_SECRET_KEY"
        SECRETS_UPDATED=true
    fi
    
    # Generate LITELLM_MASTER_KEY (keep sk- prefix for OpenAI compatibility)
    if grep -q "LITELLM_MASTER_KEY=sk-GENERATE_ME_WITH_OPENSSL" "${REPO_ROOT}/.env"; then
        NEW_SECRET=$(generate_secret)
        sed -i.bak "s|LITELLM_MASTER_KEY=sk-GENERATE_ME_WITH_OPENSSL|LITELLM_MASTER_KEY=sk-${NEW_SECRET}|g" "${REPO_ROOT}/.env"
        print_success "Generated LITELLM_MASTER_KEY"
        SECRETS_UPDATED=true
    fi
    
    rm -f "${REPO_ROOT}/.env.bak"
fi

# Check if passwords need to be set
if grep -q "CHANGE_ME_BEFORE_DEPLOY" "${REPO_ROOT}/.env" 2>/dev/null; then
    print_warning "⚠️  Placeholder passwords detected in .env!"
    print_info "Please edit .env and replace CHANGE_ME_BEFORE_DEPLOY with secure passwords:"
    print_info "  - POSTGRES_PASSWORD"
    print_info "  - ADMIN_PASSWORD"
    print_info "  - PGADMIN_PASSWORD"
    print_info "  - AUTHENTIK_BOOTSTRAP_PASSWORD"
    echo ""
    print_info "Or run: openssl rand -base64 16 to generate random passwords"
    print_error "Cannot continue with placeholder passwords. Please update .env and run again."
fi

# Reload environment after updates
if [ "$SECRETS_UPDATED" = true ]; then
    set -a
    source "${REPO_ROOT}/.env"
    set +a
    print_info "Secrets have been generated and saved to .env"
fi

# Note: database directory now lives in common/ and doesn't need creation

# ------------------------------------------------------------------------------
# STEP 3.5: SETUP SSL CERTIFICATES AND DNS
# ------------------------------------------------------------------------------

print_header "STEP 3.5: Setting Up Domain Routing (${PLUTO_DOMAIN:-pluto.local})"

# Generate SSL certificates for HTTPS
generate_ssl_certs

# Add entries to /etc/hosts for *.pluto.local domains
setup_hosts_file

# Install CA to macOS keychain for Chrome trust
install_ca_to_keychain

# ------------------------------------------------------------------------------
# STEP 4: CHECK AWS CREDENTIALS
# ------------------------------------------------------------------------------

print_header "STEP 4: Checking AWS Configuration"

# Check if AWS credentials are configured (best practice: use aws configure)
if [ ! -f ~/.aws/credentials ]; then
    print_warning "AWS credentials not found!"
    print_warning "LiteLLM will not be able to connect to Bedrock."
    echo ""
    print_info "To set up AWS credentials (recommended approach):"
    print_info "  1. Install AWS CLI if not installed"
    print_info "  2. Run: aws configure"
    print_info "  3. Enter your Access Key ID, Secret Access Key, and region"
    print_info "  4. Restart LiteLLM: docker compose restart litellm"
    echo ""
else
    print_success "AWS credentials found at ~/.aws/credentials"
fi

# ------------------------------------------------------------------------------
# STEP 5: START THE SERVICES
# ------------------------------------------------------------------------------

print_header "STEP 5: Starting Services"

print_info "Pulling container images (this may take a few minutes on first run)..."
docker compose pull

print_info "Starting all services..."
docker compose up -d

# Wait a moment for services to start
print_info "Waiting for services to initialize..."
sleep 5

# ------------------------------------------------------------------------------
# STEP 6: PULL OLLAMA EMBEDDING MODEL
# ------------------------------------------------------------------------------
# OpenWebUI uses Ollama for RAG embeddings. We need to pull the model.

print_header "STEP 6: Setting Up Ollama Embedding Model"

print_info "Waiting for Ollama to be ready..."
MAX_ATTEMPTS=30
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if docker exec infra-ollama ollama list > /dev/null 2>&1; then
        print_success "Ollama is ready!"
        break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 2
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    print_warning "Ollama not ready after ${MAX_ATTEMPTS} attempts, skipping model pull"
else
    # Check if model already exists
    if docker exec infra-ollama ollama list 2>/dev/null | grep -q "nomic-embed-text"; then
        print_info "nomic-embed-text model already installed"
    else
        print_info "Pulling nomic-embed-text model (required for RAG embeddings)..."
        docker exec infra-ollama ollama pull nomic-embed-text
        if [ $? -eq 0 ]; then
            print_success "nomic-embed-text model installed"
        else
            print_warning "Failed to pull nomic-embed-text model. You can pull it manually with:"
            echo "  docker exec infra-ollama ollama pull nomic-embed-text"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# STEP 7: CREATE OPENWEBUI ADMIN ACCOUNT (OPTIONAL)
# ------------------------------------------------------------------------------
# OpenWebUI doesn't support creating an admin via config files, but we can
# automate it using their signup API. The first user to sign up automatically
# becomes an admin.

print_header "STEP 7: Setting Up OpenWebUI Admin"

OPENWEBUI_BOOTSTRAP_ADMIN="${OPENWEBUI_BOOTSTRAP_ADMIN:-false}"
if [ "${OPENWEBUI_BOOTSTRAP_ADMIN}" != "true" ]; then
    print_info "OpenWebUI admin bootstrap disabled (OPENWEBUI_BOOTSTRAP_ADMIN=false)"
else

# Admin credentials - these come from .env (required, no defaults)
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${PLUTO_DOMAIN:-pluto.local}}"
ADMIN_NAME="${ADMIN_NAME:-Admin}"

# Build URL using dynamic domain
OPENWEBUI_URL="https://openwebui.${PLUTO_DOMAIN:-pluto.local}"
MAX_WAIT=120  # Maximum seconds to wait for OpenWebUI
WAIT_INTERVAL=5


print_info "Waiting for OpenWebUI to be ready..."

# Wait for OpenWebUI to respond to health checks
# OpenWebUI can take 30-60 seconds to fully start on first run
elapsed=0
while [ $elapsed -lt $MAX_WAIT ]; do
    # Try to reach the OpenWebUI API (-k for self-signed cert)
    if curl -sk "${OPENWEBUI_URL}/api/config" > /dev/null 2>&1; then

        print_success "OpenWebUI is ready!"
        break
    fi
    
    # Show progress every 10 seconds
    if [ $((elapsed % 10)) -eq 0 ] && [ $elapsed -gt 0 ]; then
        print_info "Still waiting... (${elapsed}s elapsed)"
    fi
    
    sleep $WAIT_INTERVAL
    elapsed=$((elapsed + WAIT_INTERVAL))
done

# Check if we timed out
if [ $elapsed -ge $MAX_WAIT ]; then
    print_warning "OpenWebUI didn't respond within ${MAX_WAIT}s"
    print_warning "You may need to create the admin account manually at ${OPENWEBUI_URL}"
else
    # Try to create the admin account
    # The signup endpoint returns different responses based on whether it succeeds
    print_info "Creating admin account..."
    
    # Make the signup request
    response=$(curl -sk -X POST "${OPENWEBUI_URL}/api/v1/auths/signup" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\",\"name\":\"${ADMIN_NAME}\"}" \
        -w "\n%{http_code}")
    
    # Extract HTTP status code (last line) and response body
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    # Check if signup was successful
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        print_success "Admin account created successfully!"
        print_info "Email: ${ADMIN_EMAIL}"
        # SECURITY: Don't echo password to terminal
        print_info "Password: (as configured in .env)"
        echo ""
        print_warning "IMPORTANT: Ensure you've set a strong password in .env!"
    elif echo "$body" | grep -q "already exists\|already registered\|already in use"; then
        print_info "Admin account already exists (skipping creation)"
    else
        # Some other error occurred
        print_warning "Could not create admin account automatically"
        print_info "You can create it manually at ${OPENWEBUI_URL}"
        print_info "Response: $body"
    fi
fi

fi

# ------------------------------------------------------------------------------
# STEP 8: SHOW STATUS AND ACCESS INFO
# ------------------------------------------------------------------------------

print_header "STEP 9: Deployment Complete! 🎉"

# Build domain variable for output
DOMAIN="${PLUTO_DOMAIN:-pluto.local}"

echo ""
echo -e "${GREEN}All services are starting up!${NC}"
echo ""
echo -e "${CYAN}Access your services at:${NC}"
echo ""
echo -e "  🌐 Portal:       ${YELLOW}https://${DOMAIN}${NC}"
echo -e "  💬 OpenWebUI:    ${YELLOW}https://openwebui.${DOMAIN}${NC}"
echo -e "  🔀 LiteLLM:      ${YELLOW}https://litellm.${DOMAIN}${NC}"
echo -e "  ⚡ n8n:          ${YELLOW}https://n8n.${DOMAIN}${NC}"
echo -e "  🌳 MCPJungle:    ${YELLOW}https://mcp.${DOMAIN}${NC}"
echo -e "  🔍 DuckDuckGo:   ${YELLOW}https://ddg.${DOMAIN}${NC}"
echo ""
echo -e "  ${PURPLE}Admin Tools (port 8443):${NC}"
echo -e "  🐘 pgAdmin:      ${YELLOW}https://pgadmin.${DOMAIN}:8443${NC}"
echo -e "  📊 Qdrant:       ${YELLOW}https://qdrant.${DOMAIN}:8443${NC}"
echo -e "  ⚙️  Traefik:      ${YELLOW}https://traefik.${DOMAIN}:8443${NC}"
echo -e "  🗄️  PostgreSQL:   ${YELLOW}localhost:5432${NC} (local only)"
echo ""
echo -e "${YELLOW}⚠️  NOTE: Your browser will show a certificate warning (self-signed).${NC}"
echo -e "${YELLOW}   Click 'Advanced' → 'Proceed' to continue.${NC}"
echo ""
echo -e "${PURPLE}Credentials:${NC}"
echo -e "  Configured in your ${YELLOW}.env${NC} file"
echo ""
echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${PURPLE}  CONNECT OPENWEBUI TO MCPJUNGLE (One-time setup)${NC}"
echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  1. Open OpenWebUI: ${YELLOW}https://openwebui.${DOMAIN}${NC}"
echo -e "  2. Go to: ${YELLOW}⚙️ Admin Settings → External Tools${NC}"
echo -e "  3. Click ${YELLOW}+ Add Server${NC}"
echo -e "  4. Set Type: ${YELLOW}MCP (Streamable HTTP)${NC}"
echo -e "  5. Set URL:  ${YELLOW}http://pluto-mcpjungle:8080/mcp${NC}"
echo -e "  6. Click ${YELLOW}Save${NC}"
echo ""
echo -e "  Now OpenWebUI can use all MCP tools (search, browser, etc.)!"
echo ""
echo -e "${PURPLE}Useful Commands:${NC}"
echo -e "  ${YELLOW}docker compose logs -f${NC}        # View live logs"
echo -e "  ${YELLOW}docker compose ps${NC}             # Check service status"
echo -e "  ${YELLOW}docker compose down${NC}           # Stop all services"
echo -e "  ${YELLOW}./teardown.sh${NC}                 # Full teardown for testing"
echo ""
echo -e "${GREEN}Note: Services may take 30-60 seconds to fully start.${NC}"
echo -e "${GREEN}If a service isn't responding, wait a moment and try again.${NC}"
echo ""

# Show current status
print_header "Current Service Status"
docker compose ps
