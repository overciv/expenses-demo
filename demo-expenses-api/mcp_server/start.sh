#!/usr/bin/env bash
# start.sh — run the Expenses MCP server
# Usage:
#   OKTA_ACCESS_TOKEN=<token> ./start.sh
#   OR
#   OKTA_TOKEN_ENDPOINT=https://... OKTA_CLIENT_ID=... OKTA_CLIENT_SECRET=... ./start.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/.venv"

if [ ! -d "$VENV" ]; then
  echo "Creating virtualenv..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q -r "$SCRIPT_DIR/requirements.txt"
fi

export EXPENSES_API_URL="${EXPENSES_API_URL:-https://7xac9s9ce6.execute-api.us-east-1.amazonaws.com/demo}"
export MCP_TRANSPORT="${MCP_TRANSPORT:-streamable-http}"
export MCP_PORT="${MCP_PORT:-8001}"

exec "$VENV/bin/python" "$SCRIPT_DIR/server.py"
