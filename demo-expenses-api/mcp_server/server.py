"""
Expenses MCP Server
Wraps the AWS Expenses REST API as MCP tools using FastMCP 3.x.

Authentication: Okta JWT (same issuer/audience as the REST API).
Incoming Bearer tokens are validated against Okta's JWKS, then forwarded
to the AWS API Gateway so scope enforcement happens at both layers.

Required env vars:
  EXPENSES_API_URL   Base URL of the AWS API Gateway
                     e.g. https://7xac9s9ce6.execute-api.us-east-1.amazonaws.com/demo

  OKTA_ISSUER        Okta authorization server issuer
                     e.g. https://zelemon.oktapreview.com/oauth2/ausdo82jknZLNiOmA0x7

  OKTA_AUDIENCE      Audience claim the Okta AS puts in tokens (aud)
                     e.g. api://expenses

Optional:
  MCP_BASE_URL       Public HTTPS URL of this server (used in OAuth metadata)
                     e.g. https://abc.us-east-1.awsapprunner.com
  MCP_PORT           Bind port  (default: 8001)
  MCP_HOST           Bind host  (default: 0.0.0.0)
  MCP_TRANSPORT      streamable-http | sse | stdio  (default: streamable-http)
"""

import os
import sys

import httpx
import jwt
from jwt import PyJWKClient
from starlette.requests import Request
from starlette.responses import JSONResponse

from fastmcp import FastMCP
from fastmcp.server.auth import AccessToken, RemoteAuthProvider, TokenVerifier
from fastmcp.server.dependencies import get_access_token

# ─────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────

OKTA_ISSUER   = os.environ.get("OKTA_ISSUER",   "")
OKTA_AUDIENCE = os.environ.get("OKTA_AUDIENCE", "api://expenses")
JWKS_URI      = f"{OKTA_ISSUER.rstrip('/')}/v1/keys"
EXPENSES_URL  = os.environ.get("EXPENSES_API_URL", "").rstrip("/")

# ─────────────────────────────────────────────────────────────
# Okta JWT token verifier (plugs into FastMCP's auth system)
# ─────────────────────────────────────────────────────────────

_jwks_client = PyJWKClient(JWKS_URI, cache_keys=True, lifespan=300)


class OktaTokenVerifier(TokenVerifier):
    """Validates Okta-issued JWTs against the org's JWKS endpoint."""

    async def verify_token(self, token: str) -> AccessToken | None:
        try:
            signing_key = _jwks_client.get_signing_key_from_jwt(token)
            claims = jwt.decode(
                token,
                signing_key.key,
                algorithms=["RS256"],
                audience=OKTA_AUDIENCE,
                issuer=OKTA_ISSUER,
                options={"require": ["sub", "iat", "exp"]},
            )
        except jwt.ExpiredSignatureError:
            return None
        except jwt.InvalidTokenError:
            return None

        # Extract scopes: Okta uses "scp" (list) or "scope" (space-separated string)
        raw_scopes = claims.get("scp") or claims.get("scope") or []
        if isinstance(raw_scopes, str):
            raw_scopes = raw_scopes.split()

        return AccessToken(
            token=token,
            client_id=claims.get("cid") or claims.get("client_id") or claims.get("sub", ""),
            scopes=raw_scopes,
            expires_at=claims.get("exp"),
            claims=claims,
        )


# ─────────────────────────────────────────────────────────────
# FastMCP server with Okta auth
# ─────────────────────────────────────────────────────────────

_base_url = os.environ.get("MCP_BASE_URL", f"http://localhost:{os.environ.get('MCP_PORT', '8001')}")

_auth = RemoteAuthProvider(
    token_verifier=OktaTokenVerifier(),
    authorization_servers=[OKTA_ISSUER],
    base_url=_base_url,
    scopes_supported=["expenses:read", "expenses:write", "expenses:delete"],
    resource_name="Expenses MCP Server",
)

mcp = FastMCP(
    name="expenses-mcp",
    instructions="Company expenses API — list and create expense records.",
    auth=_auth,
)


# ─────────────────────────────────────────────────────────────
# RFC 9728 root-path alias for protected resource metadata
#
# RemoteAuthProvider already serves the canonical metadata at
# /.well-known/oauth-protected-resource/mcp (RFC 9728 §3.1 path-scoped).
# Some MCP clients fall back to the root location when the path-scoped
# URL is not advertised in WWW-Authenticate, so mirror it here.
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
# HTTP helper — always forwards the caller's validated token
# ─────────────────────────────────────────────────────────────

async def _bearer() -> str:
    """Return the Bearer token from the current MCP request context."""
    access_token = get_access_token()
    if not access_token:
        raise PermissionError("No access token in request context.")
    return access_token.token


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
            f"Forbidden (403) — the current token is missing the required scope{scope_msg} "
            f"for this operation. Ask your administrator to grant the `{required_scope}` scope "
            f"to your Okta application. After the scope is granted, wait 5 minutes before "
            f"retrying — this is the token cache expiration time needed for the new grant to "
            f"take effect."
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
        sys.exit("ERROR: OKTA_ISSUER is required (e.g. https://<org>.okta.com/oauth2/<auth-server-id>).")

    transport = os.environ.get("MCP_TRANSPORT", "streamable-http")
    host      = os.environ.get("MCP_HOST",      "0.0.0.0")
    port      = int(os.environ.get("MCP_PORT",  "8001"))

    print(f"Expenses MCP Server")
    print(f"  Expenses API  : {EXPENSES_URL}")
    print(f"  Okta issuer   : {OKTA_ISSUER}")
    print(f"  Audience      : {OKTA_AUDIENCE}")
    print(f"  JWKS URI      : {JWKS_URI}")
    print(f"  Public URL    : {_base_url}")
    print(f"  Transport     : {transport}")
    if transport != "stdio":
        print(f"  Listening     : http://{host}:{port}/mcp")
        print(f"  Metadata      : {_base_url.rstrip('/')}/.well-known/oauth-protected-resource")
    print()

    mcp.run(transport=transport, host=host, port=port)
