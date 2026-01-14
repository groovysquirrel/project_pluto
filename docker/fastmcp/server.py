"""
Project Pluto - FastMCP Server
==============================

This is your custom MCP server powered by FastMCP.
Add new tools by creating functions decorated with @mcp.tool

MCP Endpoint: http://app-fastmcp:8000/mcp (for OpenWebUI/n8n)

Example: Connect OpenWebUI to this endpoint:
  Settings → External Tools → Add Server
  Type: MCP (Streamable HTTP)
  URL: http://app-fastmcp:8000/mcp
"""

from fastmcp import FastMCP

# Create the MCP server
mcp = FastMCP(
    name="Project Pluto MCP",
)


# =============================================================================
# EXAMPLE TOOLS - Modify or add your own!
# =============================================================================

@mcp.tool
def hello_world(name: str = "World") -> str:
    """
    A simple greeting tool to test MCP connectivity.
    
    Args:
        name: The name to greet
        
    Returns:
        A friendly greeting message
    """
    return f"Hello, {name}! 👋 Your MCP server is working!"


@mcp.tool
def calculate(expression: str) -> str:
    """
    Safely evaluate a mathematical expression.
    
    Args:
        expression: A math expression like "2 + 2" or "10 * 5"
        
    Returns:
        The result of the calculation
    """
    # Safe evaluation - only allows math operations
    allowed_chars = set("0123456789+-*/.() ")
    if not all(c in allowed_chars for c in expression):
        return "Error: Only numbers and basic math operators (+, -, *, /, .) are allowed"
    
    try:
        result = eval(expression)
        return f"{expression} = {result}"
    except Exception as e:
        return f"Error: {str(e)}"


@mcp.tool
def current_time() -> str:
    """
    Get the current date and time.
    
    Returns:
        Current timestamp in human-readable format
    """
    from datetime import datetime
    now = datetime.now()
    return now.strftime("%Y-%m-%d %H:%M:%S")


# =============================================================================
# ADD YOUR CUSTOM TOOLS BELOW
# =============================================================================
# 
# Example:
# 
# @mcp.tool
# def my_custom_tool(param1: str, param2: int = 10) -> dict:
#     """
#     Description of what your tool does.
#     
#     Args:
#         param1: Description of param1
#         param2: Description of param2 (default: 10)
#         
#     Returns:
#         Whatever your tool returns
#     """
#     # Your logic here
#     return {"result": param1, "count": param2}
#


# =============================================================================
# SERVER STARTUP
# =============================================================================

if __name__ == "__main__":
    # Run HTTP server
    # MCP endpoint will be at: http://localhost:8000/mcp
    mcp.run(
        transport="http",
        host="0.0.0.0",
        port=8000,
    )
