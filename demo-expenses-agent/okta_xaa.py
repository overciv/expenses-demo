"""
Okta Cross-App Access token exchange using the official Okta Python SDK.

Flow:
  Stage 2: org-issued ID token → ID-JAG  (org AS: /oauth2/v1/token)
  Stage 3: ID-JAG → expenses access token (custom AS: /oauth2/<id>/v1/token)

The SDK uses /.well-known/oauth-authorization-server (RFC 8414) for discovery,
which correctly advertises token-exchange on the org AS.

Prerequisite: a Resource Connection must be configured in Okta Admin Console
linking this AI Agent app to the custom AS (Security → Identity → AI Agents).
"""

import asyncio
import base64
import concurrent.futures
import json
import logging
import os
from typing import Callable, Optional


from okta_client.authfoundation import (
    APIClientListener,
    APIRetry,
    HTTPRequest,
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

OKTA_ORG_URL          = os.environ["OKTA_ORG_URL"]
OKTA_ISSUER           = os.environ["OKTA_ISSUER"]
OKTA_WEBAPP_CLIENT_ID = os.environ["OKTA_WEBAPP_CLIENT_ID"]   # Web App — used as audience/target context
OKTA_AGENT_CLIENT_ID  = os.environ["OKTA_AGENT_CLIENT_ID"]    # AI Agent client ID — used in client_assertion
OKTA_PRIVATE_KEY_PEM  = os.environ["OKTA_PRIVATE_KEY_PEM"]    # RSA private key PEM for the agent
OKTA_PRIVATE_KEY_ID   = os.environ.get("OKTA_PRIVATE_KEY_ID", "expenses-agent-key-1")

_ORG_TOKEN_ENDPOINT    = f"{OKTA_ORG_URL.rstrip('/')}/oauth2/v1/token"
_CUSTOM_TOKEN_ENDPOINT = f"{OKTA_ISSUER.rstrip('/')}/v1/token"

# Scope fallback ladder — tried in order, dropping the least-essential scope each time.
# Most optional scopes are listed last so they are dropped first on invalid_scope errors.
_SCOPE_LADDER = [
    ["expenses:read", "expenses:write", "expenses:delete"],
    ["expenses:read", "expenses:write"],
    ["expenses:read"],
]


def _decode_claims(raw_jwt: str) -> dict:
    """Decode JWT payload via direct base64 — returns every claim without filtering."""
    try:
        payload = raw_jwt.split(".")[1]
        # Restore standard base64 padding
        payload += "=" * (4 - len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return {}


def _safe_claims(claims: dict) -> dict:
    keys = ("iss", "sub", "aud", "exp", "iat", "scp", "scope", "cid", "ver")
    return {k: claims[k] for k in keys if k in claims}


class _HTTPLogger(APIClientListener):
    """Logs every HTTP request the SDK makes — confirms which AS endpoint is called."""

    def __init__(self, label: str, dbg: Callable):
        self._label = label
        self._dbg   = dbg

    def will_send(self, client, request: HTTPRequest) -> None:
        msg = f"[HTTP/{self._label}] {request.method} {request.url}"
        logger.info(msg)
        self._dbg("XAA", "req", msg)

    def did_send(self, client, request: HTTPRequest, response) -> None:
        msg = f"[HTTP/{self._label}] → {response.status_code}"
        logger.info(msg)
        self._dbg("XAA", "info", msg)

    def did_send_error(self, client, request: HTTPRequest, error: Exception) -> None:
        logger.error("[HTTP/%s] ERROR: %s", self._label, error)
        self._dbg("XAA", "err", f"[HTTP/{self._label}] ERROR: {error}")

    def should_retry(self, client, request: HTTPRequest, rate_limit=None):
        return APIRetry.default()


class _Listener(CrossAppAccessFlowListener):
    def __init__(self, dbg: Optional[Callable]):
        self._dbg = dbg or (lambda *a, **kw: None)

    def will_exchange_token_for_id_jag(self, flow, subject_token_type):
        msg = f"Stage 2 — exchanging {subject_token_type} → ID-JAG  (org AS: {_ORG_TOKEN_ENDPOINT})"
        logger.info("[XAA] %s", msg)
        self._dbg("XAA", "req", msg)

    def did_exchange_token_for_id_jag(self, flow, id_jag_token):
        # Show ALL claims for the ID-JAG so agent_id and actor claims are visible
        all_claims = _decode_claims(id_jag_token.access_token)
        msg = f"Stage 2 — ID-JAG received (expires_in={id_jag_token.expires_in}s)"
        logger.info("[XAA] %s — claims: %s", msg, all_claims)
        self._dbg("XAA", "ok",  msg)
        self._dbg("XAA", "tok", "ID-JAG decoded claims (all)", all_claims)

    def will_exchange_id_jag_for_access_token(self, flow, id_jag_token):
        msg = f"Stage 3 — exchanging ID-JAG → expenses access token  (custom AS: {_CUSTOM_TOKEN_ENDPOINT})"
        logger.info("[XAA] %s", msg)
        self._dbg("XAA", "req", msg)

    def did_exchange_id_jag_for_access_token(self, flow, access_token):
        all_claims = _decode_claims(access_token.access_token)
        msg = f"Stage 3 — expenses access token received (expires_in={access_token.expires_in}s)"
        logger.info("[XAA] %s — claims: %s", msg, all_claims)
        self._dbg("XAA", "ok",  msg)
        self._dbg("XAA", "tok", "Expenses access token decoded claims (all)", all_claims)

    def authentication_started(self, flow): pass
    def authentication_finished(self, flow, token): pass
    def authentication_failed(self, flow, error): pass


async def _exchange(org_id_token: str, scopes: list, dbg: Optional[Callable]) -> str:
    """Single Cross-App Access exchange attempt with the given scope list."""
    _dbg = dbg or (lambda *a, **kw: None)

    _dbg("XAA", "info",
         f"CrossAppAccessFlow — org AS: {OKTA_ORG_URL}  |  target: {OKTA_ISSUER}  |  "
         f"client: {OKTA_AGENT_CLIENT_ID}  |  scopes: {' '.join(scopes)}")

    key_provider = LocalKeyProvider.from_pem(
        OKTA_PRIVATE_KEY_PEM, algorithm="RS256", key_id=OKTA_PRIVATE_KEY_ID,
    )
    client_auth = ClientAssertionAuthorization(
        assertion_claims=JWTBearerClaims(
            issuer=OKTA_AGENT_CLIENT_ID,
            subject=OKTA_AGENT_CLIENT_ID,
            audience=_ORG_TOKEN_ENDPOINT,
            expires_in=300,
        ),
        key_provider=key_provider,
    )

    config = OAuth2ClientConfiguration(
        issuer=OKTA_ORG_URL, base_url=OKTA_ORG_URL, client_authorization=client_auth,
    )
    client = OAuth2Client(configuration=config)
    client.listeners.add(_HTTPLogger("orgAS", _dbg))

    target = CrossAppAccessTarget(issuer=OKTA_ISSUER)
    flow   = CrossAppAccessFlow(client=client, target=target)
    flow.listeners.add(_Listener(_dbg))
    flow.jwt_bearer_flow.client.listeners.add(_HTTPLogger("customAS", _dbg))

    try:
        await flow.start(token=org_id_token, audience=OKTA_ISSUER,
                         scope=scopes, token_type="id_token")
    except Exception as e:
        _dbg("XAA", "err", f"flow.start() failed: {type(e).__name__}: {e}")
        logger.exception("XAA flow.start() failed")
        raise

    try:
        access_token = await flow.resume()
    except Exception as e:
        _dbg("XAA", "err", f"flow.resume() failed: {type(e).__name__}: {e}")
        logger.exception("XAA flow.resume() failed")
        raise

    return access_token.access_token


async def _exchange_with_scope_fallback(org_id_token: str, dbg: Optional[Callable]) -> str:
    """Try the full scope ladder, dropping forbidden scopes on each invalid_scope error."""
    _dbg = dbg or (lambda *a, **kw: None)
    last_exc: Optional[Exception] = None

    for i, scopes in enumerate(_SCOPE_LADDER):
        try:
            result = await _exchange(org_id_token, scopes, dbg)
            if i > 0:
                _dbg("XAA", "ok",
                     f"Token exchange succeeded with reduced scopes: {', '.join(scopes)}")
            return result

        except Exception as e:
            last_exc = e
            err_str  = str(e).lower()
            is_scope_error = (
                "invalid_scope" in err_str or
                ("scope" in err_str and any(w in err_str for w in ("not", "invalid", "grant", "allow")))
            )

            if is_scope_error and i < len(_SCOPE_LADDER) - 1:
                dropped     = set(scopes) - set(_SCOPE_LADDER[i + 1])
                next_scopes = _SCOPE_LADDER[i + 1]
                _dbg("XAA", "info",
                     f"Scope(s) not allowed by Resource Connection: {', '.join(dropped)}. "
                     f"Retrying with: {', '.join(next_scopes)}")
            else:
                raise  # non-scope error, or exhausted all fallbacks

    raise last_exc  # type: ignore[misc]


def get_expenses_access_token(org_id_token: str, dbg: Optional[Callable] = None) -> str:
    """Run the Cross-App Access exchange in a dedicated thread (avoids event loop conflicts)."""
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(asyncio.run, _exchange_with_scope_fallback(org_id_token, dbg)).result()
