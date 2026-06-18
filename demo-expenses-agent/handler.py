"""
BFF Lambda — org-token endpoint only.

In the AgentCore architecture the /chat route is handled by AgentCore Runtime.
This Lambda remains as a Backend-For-Frontend solely to exchange the browser's
PKCE authorization code for an org-issued ID token, which the SPA then sends
directly to AgentCore Runtime.

Routes:
  POST /org-token  { code, code_verifier, redirect_uri } → { id_token }
"""

import json
import logging
import os

from org_token import exchange_code_for_org_id_token

logger = logging.getLogger()
logger.setLevel(logging.INFO)

CORS_HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
}


def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    if method == "OPTIONS":
        return {"statusCode": 200, "headers": CORS_HEADERS, "body": ""}

    try:
        body = json.loads(event.get("body") or "{}")
    except (json.JSONDecodeError, ValueError):
        return _resp(400, {"error": "Invalid JSON body"})

    code = (body.get("code") or "").strip()
    code_verifier = (body.get("code_verifier") or "").strip()
    redirect_uri = (body.get("redirect_uri") or "").strip()

    if not all([code, code_verifier, redirect_uri]):
        return _resp(400, {"error": "code, code_verifier and redirect_uri are required"})

    try:
        id_token = exchange_code_for_org_id_token(code, code_verifier, redirect_uri)
        return _resp(200, {"id_token": id_token})
    except Exception as exc:
        logger.exception("Org token exchange failed")
        return _resp(500, {"error": str(exc)})


def _resp(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": CORS_HEADERS,
        "body": json.dumps(body),
    }
