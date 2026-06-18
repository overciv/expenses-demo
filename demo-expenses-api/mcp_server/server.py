"""
Expenses MCP Server
Wraps the AWS Expenses REST API as MCP tools using FastMCP 3.x.

Authentication model:
  MCP protocol handshake (initialize, tools/list) is unauthenticated — this
  allows the AgentCore Gateway to discover the tool schema at target registration
  time without needing credentials.

  Tool execution (tools/call) requires a valid Okta Bearer token. The Bearer
  token is extracted by middleware into a context variable.  _bearer() validates
  it against Okta JWKS and raises PermissionError on failure, which FastMCP
  surfaces as an MCP error response (not a 401).

Required env vars:
  EXPENSES_API_URL   Base URL of the AWS API Gateway
  OKTA_ISSUER        Okta authorization server issuer
  OKTA_AUDIENCE      Audience claim in tokens (default: api://expenses)

Optional:
  MCP_BASE_URL       Public HTTPS URL of this server
  MCP_PORT           Bind port  (default: 8001)
  MCP_HOST           Bind host  (default: 0.0.0.0)
"""

import contextvars
import os
import sys

import httpx
import jwt
import uvicorn
from jwt import PyJWKClient
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse

from fastmcp import FastMCP

# ─────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────

OKTA_ISSUER   = os.environ.get("OKTA_ISSUER",   "")
OKTA_AUDIENCE = os.environ.get("OKTA_AUDIENCE", "api://expenses")
JWKS_URI      = f"{OKTA_ISSUER.rstrip('/')}/v1/keys"
EXPENSES_URL  = os.environ.get("EXPENSES_API_URL", "").rstrip("/")

_base_url = os.environ.get(
    "MCP_BASE_URL",
    f"http://localhost:{os.environ.get('MCP_PORT', '8001')}",
)

# ─────────────────────────────────────────────────────────────
# Bearer token context (set per-request by middleware)
# ─────────────────────────────────────────────────────────────

_bearer_token: contextvars.ContextVar[str] = contextvars.ContextVar(
    "bearer_token", default=""
)


class _BearerExtractMiddleware(BaseHTTPMiddleware):
    """Extracts the Bearer token from every request into a context variable.

    No enforcement here — unauthenticated requests (MCP handshake, tool
    schema discovery) are allowed through.  Tool execution validates the
    token in _bearer() before forwarding it to the Expenses API.
    """

    async def dispatch(self, request: Request, call_next):
        auth = request.headers.get("Authorization", "")
        token = auth[7:].strip() if auth.upper().startswith("BEARER ") else ""
        _bearer_token.set(token)
        return await call_next(request)


# ─────────────────────────────────────────────────────────────
# Okta JWT validation (called inside tool execution only)
# ─────────────────────────────────────────────────────────────

_jwks_client = PyJWKClient(JWKS_URI, cache_keys=True, lifespan=300)


def _validate_token(token: str) -> None:
    """Raise PermissionError if token is missing or invalid."""
    if not token:
        raise PermissionError(
            "Authentication required. "
            "Connect via an Okta-authenticated MCP client with a valid Bearer token."
        )
    try:
        signing_key = _jwks_client.get_signing_key_from_jwt(token)
        jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=OKTA_AUDIENCE,
            issuer=OKTA_ISSUER,
            options={"require": ["sub", "iat", "exp"]},
        )
    except jwt.ExpiredSignatureError:
        raise PermissionError("Bearer token has expired. Please re-authenticate.")
    except jwt.InvalidTokenError as exc:
        raise PermissionError(f"Invalid Bearer token: {exc}")


# ─────────────────────────────────────────────────────────────
# FastMCP server — no server-level auth (tool-level only)
# ─────────────────────────────────────────────────────────────

mcp = FastMCP(
    name="expenses-mcp",
    instructions="Company expenses API — list, create and delete expense records.",
)

# ─────────────────────────────────────────────────────────────
# RFC 9728 protected-resource metadata
# ─────────────────────────────────────────────────────────────

_resource_url = f"{_base_url.rstrip('/')}/mcp"

_protected_resource_metadata = {
    "resource": _resource_url,
    "authorization_servers": [OKTA_ISSUER],
    "scopes_supported": ["expenses:read", "expenses:write", "expenses:delete"],
    "bearer_methods_supported": ["header"],
    "resource_name": "Expenses MCP Server",
}


@mcp.custom_route("/.well-known/oauth-protected-resource", methods=["GET", "OPTIONS"])
async def protected_resource_metadata(request: Request) -> JSONResponse:
    return JSONResponse(
        _protected_resource_metadata,
        headers={"Access-Control-Allow-Origin": "*"},
    )


# ─────────────────────────────────────────────────────────────
# HTTP helper — validates token, then forwards to Expenses API
# ─────────────────────────────────────────────────────────────

async def _bearer() -> str:
    """Return the validated Bearer token for this request."""
    token = _bearer_token.get()
    _validate_token(token)
    return token


async def _get(path: str) -> dict:
    async with httpx.AsyncClient() as client:
        r = await client.get(
            f"{EXPENSES_URL}{path}",
            headers={"Authorization": f"Bearer {await _bearer()}"},
            timeout=15,
        )
        _check(r, required_scope="expenses:read")
        return r.json()


async def _post(path: str, payload: dict) -> dict:
    async with httpx.AsyncClient() as client:
        r = await client.post(
            f"{EXPENSES_URL}{path}",
            json=payload,
            headers={"Authorization": f"Bearer {await _bearer()}"},
            timeout=15,
        )
        _check(r, required_scope="expenses:write")
        return r.json()


async def _delete(path: str) -> dict:
    async with httpx.AsyncClient() as client:
        r = await client.delete(
            f"{EXPENSES_URL}{path}",
            headers={"Authorization": f"Bearer {await _bearer()}"},
            timeout=15,
        )
        _check(r, required_scope="expenses:delete")
        return r.json()


def _check(r: httpx.Response, required_scope: str = "") -> None:
    if r.status_code == 401:
        raise PermissionError("Expenses API rejected the token (401) — token may be expired.")
    if r.status_code == 403:
        scope_msg = f" (`{required_scope}`)" if required_scope else ""
        raise PermissionError(
            f"Forbidden (403) — the current token is missing the required scope{scope_msg}. "
            f"Ask your administrator to grant `{required_scope}` to your Okta application. "
            f"After the scope is granted, wait 5 minutes before retrying."
        )
    r.raise_for_status()


# ─────────────────────────────────────────────────────────────
# Tools
# ─────────────────────────────────────────────────────────────

@mcp.tool()
async def list_expenses() -> dict:
    """
    List all company expenses.

    Returns expense records with id, description, amount, currency,
    category, submitted_by, date, and status.
    Requires scope: expenses:read
    """
    return await _get("/expenses")


@mcp.tool()
async def create_expense(
    description: str,
    amount: float,
    category: str,
    currency: str = "USD",
    date: str = "",
) -> dict:
    """
    Create a new expense record.

    Args:
        description: What the expense is for (e.g. "Team lunch at HQ")
        amount:      Amount spent as a number (e.g. 87.50)
        category:    Category — Travel, Software, Infrastructure, Meals, Training, or Other
        currency:    ISO 4217 code (default: USD)
        date:        Date as YYYY-MM-DD (default: today)

    Requires scope: expenses:write
    """
    payload: dict = {
        "description": description,
        "amount": amount,
        "category": category,
        "currency": currency,
        "source": "ai-agent",
    }
    if date:
        payload["date"] = date
    return await _post("/expenses", payload)


@mcp.tool()
async def delete_expense(expense_id: str) -> dict:
    """
    Delete an expense record by ID.

    Args:
        expense_id: The ID of the expense to delete (e.g. "exp-abc12345")

    Note: Built-in demo expenses (exp-001 to exp-004) cannot be deleted.
    Requires scope: expenses:delete
    """
    return await _delete(f"/expenses/{expense_id}")


# ─────────────────────────────────────────────────────────────
# Entrypoint
# ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if not EXPENSES_URL:
        sys.exit("ERROR: EXPENSES_API_URL is required.")
    if not OKTA_ISSUER:
        sys.exit("ERROR: OKTA_ISSUER is required.")

    transport = os.environ.get("MCP_TRANSPORT", "streamable-http")
    host      = os.environ.get("MCP_HOST",      "0.0.0.0")
    port      = int(os.environ.get("MCP_PORT",  "8001"))

    print("Expenses MCP Server")
    print(f"  Expenses API  : {EXPENSES_URL}")
    print(f"  Okta issuer   : {OKTA_ISSUER}")
    print(f"  Audience      : {OKTA_AUDIENCE}")
    print(f"  JWKS URI      : {JWKS_URI}")
    print(f"  Public URL    : {_base_url}")
    print(f"  Transport     : {transport}")
    if transport != "stdio":
        print(f"  Listening     : http://{host}:{port}/mcp")
        print(f"  Auth model    : token-level (initialize/tools/list unauthenticated)")
        print()

    if transport == "streamable-http":
        # Build the ASGI app manually so we can add middleware
        asgi_app = mcp.http_app(path="/mcp")
        asgi_app.add_middleware(_BearerExtractMiddleware)
        uvicorn.run(asgi_app, host=host, port=port)
    else:
        mcp.run(transport=transport, host=host, port=port)
