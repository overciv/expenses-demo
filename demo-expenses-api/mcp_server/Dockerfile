FROM python:3.12-slim

WORKDIR /app

# Install dependencies first (layer cache)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .

EXPOSE 8001

ENV MCP_PORT=8001
ENV MCP_HOST=0.0.0.0
ENV MCP_TRANSPORT=streamable-http

# App Runner health-check: GET /health → 200
# FastMCP exposes /.well-known/oauth-protected-resource when auth is configured;
# We use that as the health probe (always returns 200 without auth).
# App Runner uses TCP health check (configured in create-service command)
# so no Docker-level HEALTHCHECK needed here.

CMD ["python", "server.py"]
