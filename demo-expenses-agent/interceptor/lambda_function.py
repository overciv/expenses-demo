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

Caching:
  Secrets are cached in-memory per Lambda execution environment (warm invocations
  skip the Secrets Manager call). Exchanged access tokens are NOT cached because
  they are user-scoped and short-lived relative to Lambda warm duration.
"""

import asyncio
import concurrent.futures
import json
import logging
import os

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
    CrossAppAccessTarget,
)

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

XAA_SECRET_PREFIX = os.environ.get("XAA_SECRET_PREFIX", "agentcore/xaa")
REGION = os.environ.get("AWS_REGION", "us-east-1")

_secrets_client = boto3.client("secretsmanager", region_name=REGION)
_secret_cache: dict[str, dict] = {}

# Scope fallback ladder — mirrors the v1 agent behaviour.
_SCOPE_LADDER = [
    ["expenses:read", "expenses:write", "expenses:delete"],
    ["expenses:read", "expenses:write"],
    ["expenses:read"],
]


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

async def _exchange_with_scope_fallback(org_id_token: str, secret: dict) -> str:
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


async def _exchange(org_id_token: str, scopes: list[str], secret: dict) -> str:
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
    flow = CrossAppAccessFlow(client=client, target=target)

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
    return access_token.access_token


def _run_xaa(org_id_token: str, secret: dict) -> str:
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

    if not org_id_token:
        logger.warning("No X-ID-Token in request headers — forwarding without auth")
        return _build_response(body, auth_header=None)

    try:
        secret = _load_secret(agent_id)
        expenses_token = _run_xaa(org_id_token, secret)
        return _build_response(body, auth_header=f"Bearer {expenses_token}")
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


def _build_response(body, auth_header: str | None) -> dict:
    return {
        "interceptorOutputVersion": "1.0",
        "mcp": {
            "transformedGatewayRequest": {
                "headers": {"Authorization": auth_header} if auth_header else {},
                "body": body,
            }
        },
    }
