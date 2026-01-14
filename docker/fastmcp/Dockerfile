FROM lscr.io/linuxserver/code-server:latest

# =============================================================================
# FastMCP IDE Container
# =============================================================================
# Combines code-server (VS Code in browser) with FastMCP for a complete
# MCP development environment.
#
# Access:
#   - IDE:  https://mcp.pluto.local (code-server)
#   - API:  https://mcp.pluto.local/mcp (FastMCP endpoint)
# =============================================================================

# Install Python, Node.js, and dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    curl \
    supervisor \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/* \
    && npm i -g @continuedev/cli

# Create Python virtual environment and install FastMCP
RUN python3 -m venv /opt/fastmcp-venv && \
    /opt/fastmcp-venv/bin/pip install --no-cache-dir \
    fastmcp \
    uvicorn \
    watchdog

# Create workspace directory for MCP servers
RUN mkdir -p /config/workspace/servers

# Stash default server template outside /config so volume mounts stay writable
RUN mkdir -p /defaults
COPY server.py /defaults/server.py.default
COPY continue-config.yaml /defaults/continue-config.yaml

# Preinstall code-server extensions outside /config so we can seed the volume
# Download Continue v1.3.28 directly (newer version with @File support)
RUN mkdir -p /defaults/extensions && \
    curl -sL "https://open-vsx.org/api/Continue/continue/linux-x64/1.3.28/file/Continue.continue-1.3.28@linux-x64.vsix" -o /tmp/continue.vsix && \
    /app/code-server/bin/code-server \
    --extensions-dir /defaults/extensions \
    --install-extension /tmp/continue.vsix \
    --install-extension ms-python.python && \
    rm /tmp/continue.vsix

# Copy supervisor configuration
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Copy startup script
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Expose ports
# 8443 = code-server (IDE)
# 8000 = FastMCP (MCP API)
EXPOSE 8443 8000

# Environment variables
ENV PUID=1000
ENV PGID=1000
ENV TZ=America/New_York
ENV DEFAULT_WORKSPACE=/config/workspace/servers

# Health check for FastMCP
HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=30s \
    CMD curl -sf http://localhost:8000/mcp || exit 0

# Start supervisor (manages both code-server and FastMCP)
CMD ["/start.sh"]
