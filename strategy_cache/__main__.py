"""Allow ``python -m strategy_cache`` to start the read-only MCP server."""
from __future__ import annotations

from .mcp_server import main

if __name__ == "__main__":
    raise SystemExit(main())
