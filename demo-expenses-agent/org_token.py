"""
Org AS authorization code exchange using client_secret_post.

Exchanges the browser's PKCE authorization code for an org-issued ID token
using the Web App's client_secret. The resulting ID token has cid=Web App
which is required by Okta for AI Agents as the subject token.

Endpoint: POST /org-token
Input:  { code, code_verifier, redirect_uri }
Output: { id_token }
"""

import logging
import os

import requests

logger = logging.getLogger(__name__)

OKTA_ORG_URL              = os.environ["OKTA_ORG_URL"]
OKTA_WEBAPP_CLIENT_ID     = os.environ["OKTA_WEBAPP_CLIENT_ID"]
OKTA_WEBAPP_CLIENT_SECRET = os.environ["OKTA_WEBAPP_CLIENT_SECRET"]

_ORG_TOKEN_ENDPOINT = f"{OKTA_ORG_URL.rstrip('/')}/oauth2/v1/token"


def exchange_code_for_org_id_token(
    code: str,
    code_verifier: str,
    redirect_uri: str,
    dbg=None,
) -> str:
    """Exchange an authorization code for an org-issued ID token (client_secret_post)."""
    _dbg = dbg or (lambda *a, **kw: None)
    _dbg("Lambda", "req",
         f"Exchanging auth code for org ID token  "
         f"(endpoint: {_ORG_TOKEN_ENDPOINT}, client: {OKTA_WEBAPP_CLIENT_ID})")

    resp = requests.post(
        _ORG_TOKEN_ENDPOINT,
        data={
            "grant_type":    "authorization_code",
            "code":          code,
            "code_verifier": code_verifier,
            "redirect_uri":  redirect_uri,
            "client_id":     OKTA_WEBAPP_CLIENT_ID,
            "client_secret": OKTA_WEBAPP_CLIENT_SECRET,
        },
        headers={"Accept": "application/json"},
        timeout=15,
    )

    body = resp.json()
    if not resp.ok:
        err = f"{body.get('error')}: {body.get('error_description', '')}"
        _dbg("Lambda", "err", f"Code exchange failed (HTTP {resp.status_code}): {err}")
        raise RuntimeError(f"Org AS code exchange failed: {err}")

    id_token = body.get("id_token", "")
    if not id_token:
        raise RuntimeError("No id_token in org AS token response")

    logger.info("[org-token] Code exchange succeeded — cid=%s", OKTA_WEBAPP_CLIENT_ID)
    _dbg("Lambda", "ok",
         f"Org ID token obtained (cid={OKTA_WEBAPP_CLIENT_ID}) — "
         f"ready for Cross-App Access exchange")
    return id_token
