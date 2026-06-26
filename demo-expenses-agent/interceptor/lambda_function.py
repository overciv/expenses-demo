"""
AgentCore Gateway XAA Interceptor Lambda.

Fires as a REQUEST interceptor on every MCP call routed through the Gateway.
Reads the user's org-issued ID token from X-ID-Token, performs a 2-stage
Okta Cross-App Access exchange to obtain an expenses access token, and injects
it as Authorization: Bearer into the forwarded request.

Agent credentials are stored per-agent in Secrets Manager:
  path: <XAA_SECRET_PREFIX>/<agent-id>
  default: agentcore/xaa/expenses-agent

Secret JSON schema:
  {
    "okta_org_url":         "https://<org>.oktapreview.com",
    "okta_issuer":          "https://<org>.oktapreview.com/oauth2/<as-id>",
    "okta_agent_client_id": "<AI Agent client_id>",
    "okta_private_key_pem": "-----BEGIN RSA PRIVATE KEY-----\\n...",
    "okta_private_key_id":  "<key-id>",
    "scope":                "expenses:read expenses:write expenses:delete"
  }

Caching (in-memory, per warm Lambda execution environment):
  _secret_cache  — Secrets Manager credentials, keyed by agent_id.
  _token_cache   — Expenses access tokens, keyed by (agent_id, user_sub).
                   Each entry holds {token, exp} and is evicted when the
                   token has fewer than TOKEN_CACHE_BUFFER_SECS seconds left.
                   Typically valid for 1 hour; cold starts re-exchange automatically.
"""

import asyncio
import base64
import concurrent.futures
import json
import logging
import os
import time

import boto3

from okta_client.authfoundation import (
    LocalKeyProvider,
    OAuth2Client,
    OAuth2ClientConfiguration,
)
from okta_client.authfoundation.oauth2.client_authorization import ClientAssertionAuthorization
from okta_client.authfoundation.oauth2.jwt_bearer_claims import JWTBearerClaims
from okta_client.oauth2auth import (
    CrossAppAccessFlow,
    CrossAppAccessFlowListener,
    CrossAppAccessTarget,
)

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

XAA_SECRET_PREFIX = os.environ.get("XAA_SECRET_PREFIX", "agentcore/xaa")
REGION = os.environ.get("AWS_REGION", "us-east-1")

_secrets_client = boto3.client("secretsmanager", region_name=REGION)
_secret_cache: dict[str, dict] = {}

# Access token cache — keyed by (agent_id, user_sub, prompt_nonce).
# The nonce is a per-prompt UUID sent by the agent as X-Prompt-Nonce.
# Each new user prompt brings a new nonce, so the cache is automatically
# prompt-scoped: tool calls within one prompt reuse the token, but the
# next prompt always triggers a fresh XAA exchange regardless of TTL.
_token_cache: dict[tuple, dict] = {}
TOKEN_CACHE_BUFFER_SECS = 60   # evict tokens expiring within this window

# Scope fallback ladder — mirrors the v1 agent behaviour.
_SCOPE_LADDER = [
    ["expenses:read", "expenses:write", "expenses:delete"],
    ["expenses:read", "expenses:write"],
    ["expenses:read"],
]


# ── Token cache helpers ────────────────────────────────────────────────────────

def _jwt_sub(raw_jwt: str) -> str:
    """Extract the sub claim from a JWT payload without signature verification."""
    try:
        payload = raw_jwt.split(".")[1]
        payload += "=" * (4 - len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
        return claims.get("sub") or claims.get("jti") or raw_jwt[:32]
    except Exception:
        return raw_jwt[:32]


def _jwt_exp(raw_jwt: str) -> int:
    """Extract the exp claim from a JWT payload."""
    try:
        payload = raw_jwt.split(".")[1]
        payload += "=" * (4 - len(payload) % 4)
        return int(json.loads(base64.urlsafe_b64decode(payload)).get("exp", 0))
    except Exception:
        return 0


def _cached_token(
    agent_id: str, user_sub: str, prompt_nonce: str
) -> tuple[str | None, dict | None]:
    """Return (token, debug_claims) or (None, None) if not cached / expired."""
    entry = _token_cache.get((agent_id, user_sub, prompt_nonce))
    if entry and entry["exp"] - TOKEN_CACHE_BUFFER_SECS > time.time():
        logger.info("Token cache hit for agent=%s sub=%.12s… nonce=%.8s…",
                    agent_id, user_sub, prompt_nonce)
        return entry["token"], entry.get("debug_claims")
    return None, None


def _cache_token(
    agent_id: str, user_sub: str, prompt_nonce: str,
    token: str, debug_claims: dict | None = None
) -> None:
    exp = _jwt_exp(token)
    if exp:
        _token_cache[(agent_id, user_sub, prompt_nonce)] = {
            "token": token,
            "exp": exp,
            "debug_claims": debug_claims,   # stored so cache hits can also send X-Debug-Xaa
        }


# ── Secrets Manager ────────────────────────────────────────────────────────────

def _load_secret(agent_id: str) -> dict:
    if agent_id in _secret_cache:
        return _secret_cache[agent_id]
    secret_name = f"{XAA_SECRET_PREFIX}/{agent_id}"
    logger.info("Loading XAA credentials from Secrets Manager: %s", secret_name)
    response = _secrets_client.get_secret_value(SecretId=secret_name)
    secret = json.loads(response["SecretString"])
    _secret_cache[agent_id] = secret
    return secret


# ── Okta XAA exchange ──────────────────────────────────────────────────────────

class _IDJAGCapture(CrossAppAccessFlowListener):
    """Listener that captures the raw ID-JAG JWT during the XAA flow."""

    def __init__(self):
        self.id_jag_jwt: str | None = None

    def did_exchange_token_for_id_jag(self, flow, id_jag_token):
        self.id_jag_jwt = getattr(id_jag_token, "access_token", None)

    # Required interface stubs
    def will_exchange_token_for_id_jag(self, *a): pass
    def will_exchange_id_jag_for_access_token(self, *a): pass
    def did_exchange_id_jag_for_access_token(self, *a): pass
    def authentication_started(self, *a): pass
    def authentication_finished(self, *a): pass
    def authentication_failed(self, *a): pass


async def _exchange_with_scope_fallback(
    org_id_token: str, secret: dict
) -> tuple[str, str | None]:
    """Returns (expenses_access_token, id_jag_jwt_or_None)."""
    last_exc = None
    for i, scopes in enumerate(_SCOPE_LADDER):
        try:
            return await _exchange(org_id_token, scopes, secret)
        except Exception as e:
            last_exc = e
            err_str = str(e).lower()
            is_scope_error = "invalid_scope" in err_str or (
                "scope" in err_str and any(w in err_str for w in ("not", "invalid", "grant", "allow"))
            )
            if is_scope_error and i < len(_SCOPE_LADDER) - 1:
                dropped = set(scopes) - set(_SCOPE_LADDER[i + 1])
                logger.info(
                    "Scope(s) not allowed: %s. Retrying with: %s",
                    ", ".join(dropped),
                    ", ".join(_SCOPE_LADDER[i + 1]),
                )
            else:
                raise
    raise last_exc  # type: ignore[misc]


async def _exchange(
    org_id_token: str, scopes: list[str], secret: dict
) -> tuple[str, str | None]:
    """Returns (expenses_access_token, id_jag_jwt_or_None)."""
    okta_org_url = secret["okta_org_url"].rstrip("/")
    okta_issuer = secret["okta_issuer"].rstrip("/")
    agent_client_id = secret["okta_agent_client_id"]
    private_key_pem = secret["okta_private_key_pem"]
    private_key_id = secret.get("okta_private_key_id", "expenses-agent-key-1")

    org_token_endpoint = f"{okta_org_url}/oauth2/v1/token"

    key_provider = LocalKeyProvider.from_pem(
        private_key_pem, algorithm="RS256", key_id=private_key_id
    )
    client_auth = ClientAssertionAuthorization(
        assertion_claims=JWTBearerClaims(
            issuer=agent_client_id,
            subject=agent_client_id,
            audience=org_token_endpoint,
            expires_in=300,
        ),
        key_provider=key_provider,
    )
    config = OAuth2ClientConfiguration(
        issuer=okta_org_url,
        base_url=okta_org_url,
        client_authorization=client_auth,
    )
    client = OAuth2Client(configuration=config)
    target = CrossAppAccessTarget(issuer=okta_issuer)

    id_jag_capture = _IDJAGCapture()
    flow = CrossAppAccessFlow(client=client, target=target)
    flow.listeners.add(id_jag_capture)

    logger.info(
        "XAA Stage 2: org ID token → ID-JAG  (org AS: %s)", org_token_endpoint
    )
    await flow.start(
        token=org_id_token,
        audience=okta_issuer,
        scope=scopes,
        token_type="id_token",
    )

    logger.info("XAA Stage 3: ID-JAG → expenses access token  (custom AS: %s/v1/token)", okta_issuer)
    access_token = await flow.resume()
    logger.info("XAA exchange succeeded — scopes: %s", " ".join(scopes))
    return access_token.access_token, id_jag_capture.id_jag_jwt


def _run_xaa(org_id_token: str, secret: dict) -> tuple[str, str | None]:
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(
            asyncio.run, _exchange_with_scope_fallback(org_id_token, secret)
        ).result()


# ── Lambda handler ─────────────────────────────────────────────────────────────

def lambda_handler(event, context):
    logger.info("Interceptor invoked")

    mcp = event.get("mcp", {})
    gateway_request = mcp.get("gatewayRequest", {})
    headers = gateway_request.get("headers", {}) or {}
    body = gateway_request.get("body")

    # X-ID-Token carries the user's org ID token (Authorization is stripped by Gateway)
    org_id_token = headers.get("X-ID-Token") or headers.get("x-id-token", "")
    agent_id = (
        headers.get("X-Agent-ID") or headers.get("x-agent-id") or "expenses-agent"
    )
    # X-Prompt-Nonce is a per-prompt UUID from the agent — scopes the cache to one prompt
    prompt_nonce = headers.get("X-Prompt-Nonce") or headers.get("x-prompt-nonce", "")

    if not org_id_token:
        logger.warning("No X-ID-Token in request headers — forwarding without auth")
        return _build_response(body, auth_header=None)

    try:
        user_sub = _jwt_sub(org_id_token)

        # Cache hit: same prompt (same nonce) → reuse token and cached debug claims
        cached_token, cached_debug = _cached_token(agent_id, user_sub, prompt_nonce)
        if cached_token:
            # Pass the stored debug claims so every tool/call also gets X-Debug-Xaa
            return _build_response(body, auth_header=f"Bearer {cached_token}",
                                   debug_claims=cached_debug)

        # Cache miss: new prompt (new nonce) or first call → full XAA exchange
        secret = _load_secret(agent_id)
        expenses_token, id_jag_jwt = _run_xaa(org_id_token, secret)
        # Decode both real tokens and store in cache so hits can replay them
        debug_claims = {
            "expenses": _decode_token_for_debug(expenses_token),
            "id_jag":   _decode_token_for_debug(id_jag_jwt) if id_jag_jwt else None,
        }
        _cache_token(agent_id, user_sub, prompt_nonce, expenses_token, debug_claims)
        return _build_response(body, auth_header=f"Bearer {expenses_token}",
                               debug_claims=debug_claims)
    except Exception as e:
        logger.exception("XAA exchange failed: %s", e)
        # Return a 403 transformedGatewayResponse so the agent sees a clear error
        return {
            "interceptorOutputVersion": "1.0",
            "mcp": {
                "transformedGatewayResponse": {
                    "statusCode": 403,
                    "body": {
                        "jsonrpc": "2.0",
                        "error": {
                            "code": -32000,
                            "message": f"XAA token exchange failed: {e}",
                        },
                    },
                }
            },
        }


def _decode_token_for_debug(raw_jwt: str) -> dict | None:
    """Decode JWT payload for the X-Debug-Xaa header (no sig verify needed)."""
    try:
        payload = raw_jwt.split(".")[1]
        payload += "=" * (4 - len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return None


def _build_response(body, auth_header: str | None,
                    debug_claims: dict | None = None) -> dict:
    headers: dict = {}
    if auth_header:
        headers["Authorization"] = auth_header
    if debug_claims:
        # Base64-encode the claims dict so it survives as an HTTP header value
        headers["X-Debug-Xaa"] = base64.b64encode(
            json.dumps(debug_claims).encode()
        ).decode()
    return {
        "interceptorOutputVersion": "1.0",
        "mcp": {
            "transformedGatewayRequest": {
                "headers": headers,
                "body": body,
            }
        },
    }
