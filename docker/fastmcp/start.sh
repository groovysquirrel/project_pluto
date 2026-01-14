#!/bin/bash
# =============================================================================
# FastMCP IDE Startup Script
# =============================================================================

set -e

# Create log directory
mkdir -p /var/log/supervisor

# Update CA certificates to trust Pluto CA (for HTTPS to LiteLLM)
if [ -f /usr/local/share/ca-certificates/pluto-ca.crt ]; then
    update-ca-certificates 2>/dev/null || true
fi

# Remove PEP 668 restriction to allow pip/pipenv to work (safe in container)
rm -f /usr/lib/python3.12/EXTERNALLY-MANAGED 2>/dev/null || true

# Set up passwordless sudo for abc user (needed for Continue CLI)
echo "abc ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/abc
chmod 440 /etc/sudoers.d/abc

# Create helper scripts for MCP development
cat > /usr/local/bin/mcp-restart << 'EOF'
#!/bin/bash
pkill -f "server.py" 2>/dev/null
echo "MCP server restarting... (watchdog will restart it automatically)"
sleep 2
ps aux | grep -E "python.*server.py" | grep -v grep | head -1 && echo "✓ Server running"
EOF
chmod +x /usr/local/bin/mcp-restart

cat > /usr/local/bin/mcp-pip << 'EOF'
#!/bin/bash
/opt/fastmcp-venv/bin/pip "$@"
EOF
chmod +x /usr/local/bin/mcp-pip

# Add shell aliases for python/pip to use the FastMCP venv
if ! grep -q "FastMCP shortcuts" /config/.bashrc 2>/dev/null; then
    cat >> /config/.bashrc << 'EOF'

# FastMCP shortcuts
alias mcp-restart="pkill -f server.py && echo Restarting... && sleep 2 && ps aux | grep server.py | grep -v grep | head -1"
alias pip="/opt/fastmcp-venv/bin/pip"
alias python="/opt/fastmcp-venv/bin/python"
EOF
fi

# Ensure workspace exists with correct permissions
mkdir -p /config/workspace/servers
mkdir -p /config/data
mkdir -p /config/extensions
mkdir -p /config/.cache

# Fix ownership so abc user can install pip packages
chown -R abc:abc /opt/fastmcp-venv
chown -R abc:abc /config/.cache
chown -R abc:abc /usr/local/bin /usr/local/lib 2>/dev/null || true
# Link pipenv to /usr/local/bin for sudo access
ln -sf /opt/fastmcp-venv/bin/pipenv /usr/local/bin/pipenv 2>/dev/null || true
# Fix lsiopy for pipenv (linuxserver image quirk)
mkdir -p /lsiopy/bin
ln -sf /usr/bin/python3 /lsiopy/bin/python
ln -sf /usr/bin/python3 /lsiopy/bin/python3
chown -R abc:abc /lsiopy

# Seed extensions if empty (volume may mask image layer)
if [ ! -d /config/extensions ] || [ -z "$(ls -A /config/extensions 2>/dev/null)" ]; then
    mkdir -p /config/extensions
    cp -R /defaults/extensions/. /config/extensions/ 2>/dev/null || true
fi

# Copy default server if workspace is empty
if [ ! -f /config/workspace/servers/server.py ]; then
    cp /defaults/server.py.default /config/workspace/servers/server.py 2>/dev/null || true
fi

# Seed Continue extension config if missing
CONTINUE_DIR="/config/.continue"
CONTINUE_CONFIG="${CONTINUE_DIR}/config.yaml"
if [ ! -f "${CONTINUE_CONFIG}" ]; then
    mkdir -p "${CONTINUE_DIR}"
    LITELLM_BASE_URL="${LITELLM_BASE_URL:-https://litellm.pluto.local/v1}"
    LITELLM_API_KEY="${LITELLM_API_KEY:-}"
    LITELLM_MODEL="${LITELLM_MODEL:-claude-3.5-sonnet}"
    sed \
        -e "s|__LITELLM_BASE_URL__|${LITELLM_BASE_URL}|g" \
        -e "s|__LITELLM_API_KEY__|${LITELLM_API_KEY}|g" \
        -e "s|__LITELLM_MODEL__|${LITELLM_MODEL}|g" \
        /defaults/continue-config.yaml > "${CONTINUE_CONFIG}"
    echo "Continue configured for LiteLLM at ${LITELLM_BASE_URL}"
fi

# Set permissions
chown -R ${PUID:-1000}:${PGID:-1000} /config

echo "=============================================="
echo "  FastMCP IDE Starting..."
echo "=============================================="
echo "  IDE:  http://localhost:8443"
echo "  MCP:  http://localhost:8000/mcp"
echo "=============================================="

# Start supervisor
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
